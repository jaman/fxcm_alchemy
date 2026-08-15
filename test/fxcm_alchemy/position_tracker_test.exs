defmodule FxcmAlchemy.PositionTrackerTest do
  use ExUnit.Case, async: false

  alias FixAlchemy.SessionSupervisor
  alias FxcmAlchemy.FakeFixServer
  alias FxcmAlchemy.PositionTracker

  @spec_file Path.join([__DIR__, "..", "..", "priv", "specs", "FIX44.xml"])

  defmodule RecordingPubSub do
    @behaviour FixAlchemy.PubSub

    @impl FixAlchemy.PubSub
    def broadcast(server, topic, message) do
      send(Process.whereis(server), {:broadcast, topic, message})
      :ok
    end
  end

  setup do
    {:ok, server} = FakeFixServer.start_link(self())
    connection_id = "tracker_#{System.unique_integer([:positive])}"

    opts = [
      connection_id: connection_id,
      host: "127.0.0.1",
      port: FakeFixServer.port(server),
      username: "user",
      password: "pass",
      sender_comp_id: "TESTCLIENT",
      target_comp_id: "FAKE",
      account: "ACC1",
      user_on_login: true,
      heartbeat_interval: 30,
      spec_file: @spec_file,
      defer_ready: true,
      handlers: [FxcmAlchemy.Session, FxcmAlchemy.MarketData, FxcmAlchemy.Portfolio]
    ]

    start_supervised!({SessionSupervisor, opts}, restart: :temporary)
    assert_receive :fix_server_connected, 2000

    on_exit(fn ->
      Application.delete_env(:fix_alchemy, :pubsub)
    end)

    {:ok, connection_id: connection_id}
  end

  defp start_tracker(connection_id, opts \\ []) do
    start_supervised!(
      {PositionTracker, [connection_id: connection_id, base_currency: "USD"] ++ opts},
      restart: :temporary
    )
  end

  defp price_update(connection_id) do
    {:market_data_update, connection_id, "EUR/USD", %{bid: "1.0800", ask: "1.0802"}}
  end

  describe "when the session behind it has gone" do
    defp fill(position_id) do
      {:position_update,
       %{
         position_id => %{
           symbol: "GBP/JPY",
           size: "1000",
           side: :sell,
           via: :fill,
           avg_price: "214.874",
           position_id: position_id,
           last_update: DateTime.utc_now(),
           data: %{}
         }
       }}
    end

    test "a position update outlives the portfolio it would have asked" do
      tracker = start_tracker("no_session_#{System.unique_integer([:positive])}")
      ref = Process.monitor(tracker)

      send(tracker, fill("41372232"))

      refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 500

      assert Process.alive?(tracker),
             "a dead portfolio must not take the tracker down with it"
    end

    test "the position is still tracked without an account to price it against" do
      tracker = start_tracker("no_session_#{System.unique_integer([:positive])}")

      send(tracker, fill("41372232"))

      assert %{positions: positions} = :sys.get_state(tracker)
      assert Map.has_key?(positions, "41372232")
    end
  end

  describe "without a pubsub server configured" do
    test "survives a price update", %{connection_id: connection_id} do
      tracker = start_tracker(connection_id)
      ref = Process.monitor(tracker)

      send(tracker, price_update(connection_id))

      refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 500
      assert Process.alive?(tracker)
    end

    test "survives a position update", %{connection_id: connection_id} do
      tracker = start_tracker(connection_id)
      ref = Process.monitor(tracker)

      positions = %{
        "POS1" => %{position_id: "POS1", symbol: "EUR/USD", side: "1", size: "1000"}
      }

      send(tracker, {:position_update, positions})

      refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 500
      assert Process.alive?(tracker)
    end
  end

  describe "resolving the pubsub server" do
    test "prefers the tracker's own option", %{connection_id: connection_id} do
      Application.put_env(:fix_alchemy, :pubsub_server, OtherApp.PubSub)
      on_exit(fn -> Application.delete_env(:fix_alchemy, :pubsub_server) end)

      tracker = start_tracker(connection_id, pubsub_module: MyApp.PubSub)

      assert :sys.get_state(tracker).pubsub_module == MyApp.PubSub
    end

    test "falls back to the engine's server", %{connection_id: connection_id} do
      Application.put_env(:fix_alchemy, :pubsub_server, OtherApp.PubSub)
      on_exit(fn -> Application.delete_env(:fix_alchemy, :pubsub_server) end)

      assert :sys.get_state(start_tracker(connection_id)).pubsub_module == OtherApp.PubSub
    end

    test "is nil when neither is configured", %{connection_id: connection_id} do
      assert :sys.get_state(start_tracker(connection_id)).pubsub_module == nil
    end
  end

  describe "with a pubsub server configured" do
    setup do
      Process.register(self(), :test_pubsub_server)
      Application.put_env(:fix_alchemy, :pubsub, RecordingPubSub)
      :ok
    end

    test "a price on its own is noted, not published", %{connection_id: connection_id} do
      tracker = start_tracker(connection_id, pubsub_module: :test_pubsub_server)

      send(tracker, price_update(connection_id))

      refute_receive {:broadcast, _topic, {:position_update, _positions}}, 300

      assert Process.alive?(tracker),
             "a price that changes no position is worth remembering, not announcing"
    end

    test "a position opening or closing is published", %{connection_id: connection_id} do
      tracker = start_tracker(connection_id, pubsub_module: :test_pubsub_server)

      send(tracker, {:position_update, %{"P1" => held("EUR/USD", "1.0800")}})

      assert_receive {:broadcast, topic, {:position_update, _positions}}, 1000
      assert topic == "position:#{connection_id}"
    end
  end

  describe "profit and loss on demand" do
    defp held(symbol, entry) do
      %{
        symbol: symbol,
        size: "1000",
        side: :buy,
        via: :fill,
        avg_price: entry,
        position_id: "P1",
        last_update: DateTime.utc_now(),
        data: %{}
      }
    end

    test "asking prices the position against the latest quote", %{connection_id: connection_id} do
      tracker = start_tracker(connection_id)

      send(tracker, {:position_update, %{"P1" => held("EUR/USD", "1.0800")}})

      send(
        tracker,
        {:market_data_update, connection_id, "EUR/USD", %{bid: "1.0850", ask: "1.0852"}}
      )

      %{positions: positions} = PositionTracker.snapshot(connection_id)

      assert %{"P1" => priced} = positions
      assert priced.unrealized_pnl > 0, "a long held into a higher bid is in profit"
    end

    test "a later quote moves the answer without any update in between", %{
      connection_id: connection_id
    } do
      tracker = start_tracker(connection_id)

      send(tracker, {:position_update, %{"P1" => held("EUR/USD", "1.0800")}})

      send(
        tracker,
        {:market_data_update, connection_id, "EUR/USD", %{bid: "1.0850", ask: "1.0852"}}
      )

      first = PositionTracker.snapshot(connection_id).positions["P1"].unrealized_pnl

      send(
        tracker,
        {:market_data_update, connection_id, "EUR/USD", %{bid: "1.0900", ask: "1.0902"}}
      )

      second = PositionTracker.snapshot(connection_id).positions["P1"].unrealized_pnl

      assert second > first
    end

    test "with no quote yet the position is reported unpriced", %{connection_id: connection_id} do
      tracker = start_tracker(connection_id)

      send(tracker, {:position_update, %{"P1" => held("EUR/USD", "1.0800")}})

      %{positions: positions} = PositionTracker.snapshot(connection_id)

      assert Map.has_key?(positions, "P1")
    end
  end
end

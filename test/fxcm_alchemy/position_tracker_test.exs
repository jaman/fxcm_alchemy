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
      Application.delete_env(:fxcm_alchemy, :pubsub_module)
      Application.delete_env(:fix_alchemy, :pubsub)
    end)

    {:ok, connection_id: connection_id}
  end

  defp start_tracker(connection_id) do
    start_supervised!(
      {PositionTracker, [connection_id: connection_id, base_currency: "USD"]},
      restart: :temporary
    )
  end

  defp price_update(connection_id) do
    {:market_data_update, connection_id, "EUR/USD", %{bid: "1.0800", ask: "1.0802"}}
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
    test "prefers the fxcm_alchemy setting", %{connection_id: connection_id} do
      Application.put_env(:fxcm_alchemy, :pubsub_module, MyApp.PubSub)
      Application.put_env(:fix_alchemy, :pubsub_server, OtherApp.PubSub)
      on_exit(fn -> Application.delete_env(:fix_alchemy, :pubsub_server) end)

      assert :sys.get_state(start_tracker(connection_id)).pubsub_module == MyApp.PubSub
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
      Application.put_env(:fxcm_alchemy, :pubsub_module, :test_pubsub_server)
      Application.put_env(:fix_alchemy, :pubsub, RecordingPubSub)
      :ok
    end

    test "broadcasts positions and account on a price update", %{connection_id: connection_id} do
      tracker = start_tracker(connection_id)

      send(tracker, price_update(connection_id))

      assert_receive {:broadcast, topic, {:position_update, _positions}}, 1000
      assert topic == "position:#{connection_id}"
      assert Process.alive?(tracker)
    end
  end
end

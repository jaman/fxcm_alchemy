defmodule FxcmAlchemy.ClientSessionTest do
  use ExUnit.Case

  alias FixAlchemy.Parser
  alias FixAlchemy.SessionSupervisor
  alias FxcmAlchemy.FakeFixServer

  @spec_file Path.join([__DIR__, "..", "..", "priv", "specs", "FIX44.xml"])
  @soh <<1>>

  setup do
    {:ok, server} = FakeFixServer.start_link(self())
    port = FakeFixServer.port(server)
    connection_id = "fxcm_#{System.unique_integer([:positive])}"

    opts = [
      connection_id: connection_id,
      host: "127.0.0.1",
      port: port,
      username: "user",
      password: "pass",
      sender_comp_id: "TESTCLIENT",
      target_comp_id: "FAKE",
      account: "ACC1",
      user_on_login: true,
      heartbeat_interval: 1,
      spec_file: @spec_file,
      defer_ready: true,
      handlers: [FxcmAlchemy.Session, FxcmAlchemy.MarketData, FxcmAlchemy.Portfolio]
    ]

    {:ok, server: server, opts: opts, connection_id: connection_id}
  end

  defp start_session(opts) do
    sup = start_supervised!({SessionSupervisor, opts}, restart: :temporary)
    assert_receive :fix_server_connected, 2000
    sup
  end

  defp client_pid(connection_id) do
    [{pid, _}] = Registry.lookup(FixAlchemy.Registry, {connection_id, :trading})
    pid
  end

  defp complete_logon(server) do
    logon = await_message(&(Parser.extract_msg_type(&1) == "A"))
    FakeFixServer.send_raw(server, FakeFixServer.build("A", [{"98", "0"}, {"108", "1"}]))
    logon
  end

  defp await_message(matcher, timeout \\ 3000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(matcher, deadline)
  end

  defp do_await(matcher, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:server_received, message} ->
        if matcher.(message), do: message, else: do_await(matcher, deadline)
    after
      remaining -> flunk("expected FIX message was not received in time")
    end
  end

  defp refute_message(matcher, window_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    do_refute(matcher, deadline)
  end

  defp do_refute(matcher, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:server_received, message} ->
        refute matcher.(message), "received a message that should have been suppressed"
        do_refute(matcher, deadline)
    after
      remaining -> :ok
    end
  end

  defp eventually(fun, attempts \\ 60) do
    case {fun.(), attempts} do
      {true, _} ->
        :ok

      {false, 0} ->
        flunk("condition never became true")

      {false, _} ->
        Process.sleep(50)
        eventually(fun, attempts - 1)
    end
  end

  describe "message routing" do
    test "market data updates land in the MarketData process", ctx do
      start_session(ctx.opts)
      complete_logon(ctx.server)
      client = client_pid(ctx.connection_id)

      md_update =
        FakeFixServer.build("X", [
          {"268", "2"},
          {"279", "1"},
          {"269", "0"},
          {"55", "EUR/USD"},
          {"270", "1.0828"},
          {"279", "1"},
          {"269", "1"},
          {"55", "EUR/USD"},
          {"270", "1.0829"}
        ])

      FakeFixServer.send_raw(ctx.server, md_update)

      eventually(fn ->
        case FxcmAlchemy.get_instrument(client, "EUR/USD") do
          %{bid: "1.0828", ask: "1.0829"} -> true
          _ -> false
        end
      end)
    end

    test "each quote moves the price on", ctx do
      start_session(ctx.opts)
      complete_logon(ctx.server)
      client = client_pid(ctx.connection_id)

      FakeFixServer.send_raw(ctx.server, quote_for("EUR/USD", "1.0828", "1.0829"))

      eventually(fn ->
        match?(%{bid: "1.0828"}, FxcmAlchemy.get_instrument(client, "EUR/USD"))
      end)

      FakeFixServer.send_raw(ctx.server, quote_for("EUR/USD", "1.0910", "1.0911"))

      eventually(fn ->
        match?(
          %{bid: "1.0910", ask: "1.0911"},
          FxcmAlchemy.get_instrument(client, "EUR/USD")
        )
      end)
    end

    test "a market-data subscription made before logon is sent once logged in", ctx do
      start_session(ctx.opts)
      client = client_pid(ctx.connection_id)

      FxcmAlchemy.subscribe_market_data(client, ["EUR/USD"])
      complete_logon(ctx.server)

      request = await_message(&(Parser.extract_msg_type(&1) == "V"))
      assert String.contains?(request, "55=EUR/USD")
      assert String.contains?(request, "263=1")
    end

    test "a market-data subscription is re-sent on every logon (survives reconnect)", ctx do
      start_session(ctx.opts)
      complete_logon(ctx.server)
      client = client_pid(ctx.connection_id)

      FxcmAlchemy.subscribe_market_data(client, ["EUR/USD"])
      await_message(&(Parser.extract_msg_type(&1) == "V"))

      FakeFixServer.send_raw(ctx.server, FakeFixServer.build("A", [{"98", "0"}, {"108", "1"}]))

      resend =
        await_message(fn message ->
          Parser.extract_msg_type(message) == "V" and String.contains?(message, "55=EUR/USD")
        end)

      assert String.contains?(resend, "55=EUR/USD")
    end

    test "a bracket order goes out as one contingency list (35=E)", ctx do
      start_session(ctx.opts)
      complete_logon(ctx.server)
      client = client_pid(ctx.connection_id)

      :ok =
        FxcmAlchemy.bracket_order(client, "EUR/USD", 1000, :buy,
          stop_loss: 1.1300,
          take_profit: 1.1500
        )

      list = await_message(&(Parser.extract_msg_type(&1) == "E"))
      fields = Parser.split_fields(list)

      assert {"1385", "3"} in fields
      assert {"68", "3"} in fields
      assert {"73", "3"} in fields

      assert fields |> Enum.count(&match?({"11", _}, &1)) == 3
      assert fields |> Enum.filter(&match?({"583", _}, &1)) |> Enum.uniq() |> length() == 1

      sides = for {"54", side} <- fields, do: side
      assert sides == ["1", "2", "2"]

      assert {"99", "1.13"} in fields
      assert {"44", "1.15"} in fields
    end

    test "attaching protection to a position sends an OCO pair referencing the position", ctx do
      start_session(ctx.opts)
      complete_logon(ctx.server)
      client = client_pid(ctx.connection_id)

      position = %{symbol: "EUR/USD", quantity: 1000, side: :buy, pos_id: "74615492"}

      :ok =
        FxcmAlchemy.attach_protection(client, position,
          stop_loss: 1.1300,
          take_profit: 1.1500
        )

      list = await_message(&(Parser.extract_msg_type(&1) == "E"))
      fields = Parser.split_fields(list)

      assert {"1385", "1"} in fields
      assert {"68", "2"} in fields
      assert fields |> Enum.count(&match?({"9041", "74615492"}, &1)) == 2
      assert fields |> Enum.count(&match?({"77", "C"}, &1)) == 2
      assert for({"54", side} <- fields, do: side) == ["2", "2"]
    end

    test "protection with only a stop loss goes out as a single closing order", ctx do
      start_session(ctx.opts)
      complete_logon(ctx.server)
      client = client_pid(ctx.connection_id)

      position = %{symbol: "EUR/USD", quantity: 1000, side: :sell, pos_id: "74615493"}

      :ok = FxcmAlchemy.attach_protection(client, position, stop_loss: 1.1500)

      order = await_message(&(Parser.extract_msg_type(&1) == "D"))
      fields = Parser.split_fields(order)

      assert {"40", "3"} in fields
      assert {"99", "1.15"} in fields
      assert {"54", "1"} in fields
      assert {"9041", "74615493"} in fields
      assert {"77", "C"} in fields
    end

    test "orders are refused until the account is known", ctx do
      opts = Keyword.delete(ctx.opts, :account)
      start_session(opts)

      await_message(&(Parser.extract_msg_type(&1) == "A"))
      FakeFixServer.send_raw(ctx.server, FakeFixServer.build("A", [{"98", "0"}, {"108", "1"}]))
      client = client_pid(ctx.connection_id)

      assert {:error, :account_unknown} = FxcmAlchemy.order(client, "EUR/USD", 1000, :buy)

      await_message(&(Parser.extract_msg_type(&1) == "BB"))

      FakeFixServer.send_raw(
        ctx.server,
        FakeFixServer.build("BA", [{"1", "REAL_ACC"}, {"922", "5000"}])
      )

      eventually(fn -> FxcmAlchemy.order(client, "EUR/USD", 1000, :buy) == :ok end)
    end

    test "cancelling a tracked order supplies its OrderID (tag 37)", ctx do
      start_session(ctx.opts)
      complete_logon(ctx.server)
      client = client_pid(ctx.connection_id)

      FakeFixServer.send_raw(
        ctx.server,
        FakeFixServer.build("8", [
          {"37", "79663532"},
          {"11", "AUD/NZD_1784911652"},
          {"39", "0"},
          {"150", "0"},
          {"151", "1000"},
          {"55", "AUD/NZD"},
          {"54", "1"},
          {"38", "1000"}
        ])
      )

      eventually(fn -> FxcmAlchemy.get_order(client, "79663532") != nil end)

      :ok = FxcmAlchemy.cancel_order(client, "79663532")

      cancel = await_message(&(Parser.extract_msg_type(&1) == "F"))
      fields = Parser.split_fields(cancel)

      assert {"37", "79663532"} in fields
      assert {"41", "AUD/NZD_1784911652"} in fields
    end

    test "a malformed message segment is absorbed without harming the session", ctx do
      start_session(ctx.opts)
      complete_logon(ctx.server)
      client = client_pid(ctx.connection_id)

      poison = FakeFixServer.build("8", [{"55", "EUR/USD"}]) |> insert_poison_field()
      FakeFixServer.send_raw(ctx.server, poison)

      Process.sleep(200)
      assert Process.alive?(client)
      assert FxcmAlchemy.get_account(client) == "ACC1"
      assert FxcmAlchemy.get_positions(client) == %{}
    end

    test "a crashed handler process restarts without killing the session", ctx do
      start_session(ctx.opts)
      complete_logon(ctx.server)
      client = client_pid(ctx.connection_id)

      [{portfolio, _}] =
        Registry.lookup(FixAlchemy.Registry, {ctx.connection_id, :trading, :portfolio})

      Process.exit(portfolio, :kill)

      eventually(fn ->
        try do
          Process.alive?(client) and FxcmAlchemy.get_positions(client) == %{}
        catch
          :exit, _restarting -> false
        end
      end)
    end
  end

  describe "account discovery" do
    test "waits for the collateral report before requesting positions", ctx do
      opts = Keyword.delete(ctx.opts, :account)
      start_session(opts)

      await_message(&(Parser.extract_msg_type(&1) == "A"))
      FakeFixServer.send_raw(ctx.server, FakeFixServer.build("A", [{"98", "0"}, {"108", "1"}]))
      await_message(&(Parser.extract_msg_type(&1) == "BB"))

      FakeFixServer.send_raw(ctx.server, FakeFixServer.build("BG", []))
      refute_message(&(Parser.extract_msg_type(&1) == "AN"), 300)

      FakeFixServer.send_raw(
        ctx.server,
        FakeFixServer.build("BA", [{"1", "REAL_ACC"}, {"922", "5000"}])
      )

      position_request = await_message(&(Parser.extract_msg_type(&1) == "AN"))

      assert String.contains?(position_request, "1=REAL_ACC")
    end

    test "requests positions immediately when the account is configured", ctx do
      start_session(ctx.opts)
      complete_logon(ctx.server)

      position_request = await_message(&(Parser.extract_msg_type(&1) == "AN"))

      assert String.contains?(position_request, "1=ACC1")
    end

    test "a market data session never requests positions or orders", ctx do
      opts = Keyword.merge(ctx.opts, session_name: "quote", session_roles: [:market_data])
      start_session(opts)
      complete_logon(ctx.server)

      FakeFixServer.send_raw(
        ctx.server,
        FakeFixServer.build("BA", [{"1", "REAL_ACC"}, {"922", "5000"}]) <>
          FakeFixServer.build("BG", [])
      )

      refute_message(&(Parser.extract_msg_type(&1) in ["AN", "AF"]), 500)
    end
  end

  describe "session-level rejects" do
    test "a required-tag-missing reject does not blacklist the message type", ctx do
      start_session(ctx.opts)
      complete_logon(ctx.server)
      client = client_pid(ctx.connection_id)
      await_message(&(Parser.extract_msg_type(&1) == "AN"))

      FakeFixServer.send_raw(
        ctx.server,
        FakeFixServer.build("3", [
          {"372", "AN"},
          {"373", "1"},
          {"45", "4"},
          {"58", "Required tag missing"}
        ])
      )

      Process.sleep(100)
      FxcmAlchemy.request_positions(client)

      assert await_message(&(Parser.extract_msg_type(&1) == "AN"))
    end

    test "an unsupported-message-type reject does blacklist the type", ctx do
      start_session(ctx.opts)
      complete_logon(ctx.server)
      client = client_pid(ctx.connection_id)
      await_message(&(Parser.extract_msg_type(&1) == "AN"))

      FakeFixServer.send_raw(
        ctx.server,
        FakeFixServer.build("3", [{"372", "AN"}, {"373", "11"}, {"58", "Unsupported"}])
      )

      Process.sleep(100)
      FxcmAlchemy.request_positions(client)

      refute_message(&(Parser.extract_msg_type(&1) == "AN"), 500)
    end
  end

  describe "historical candles" do
    test "collects candle snapshots until the burst goes quiet", ctx do
      start_session(ctx.opts)
      complete_logon(ctx.server)
      client = client_pid(ctx.connection_id)

      task =
        Task.async(fn ->
          FxcmAlchemy.request_historical_candles(client, "EUR/USD",
            interval: 1,
            from: ~U[2026-07-22 10:00:00Z],
            to: ~U[2026-07-22 12:00:00Z]
          )
        end)

      request = await_message(&(Parser.extract_msg_type(&1) == "V"))

      assert String.contains?(request, "263=0")
      assert String.contains?(request, "9011=1")
      assert String.contains?(request, "9012=20260722")
      assert String.contains?(request, "9015=12:00:00")

      {"262", request_id} = List.keyfind(Parser.split_fields(request), "262", 0)

      FakeFixServer.send_raw(
        ctx.server,
        candle_snapshot(request_id, "20260722", "10:00:00", ~w(1.0 1.2 0.9 1.1))
      )

      FakeFixServer.send_raw(
        ctx.server,
        candle_snapshot(request_id, "20260722", "10:01:00", ~w(1.1 1.3 1.0 1.2))
      )

      assert {:ok, [first, second]} = Task.await(task, 10_000)
      assert %{open: 1.0, high: 1.2, low: 0.9, close: 1.1} = first
      assert %{open: 1.1, close: 1.2} = second
      assert second.time - first.time == 60
    end

    test "a market data request reject fails the historical request", ctx do
      start_session(ctx.opts)
      complete_logon(ctx.server)
      client = client_pid(ctx.connection_id)

      task =
        Task.async(fn ->
          FxcmAlchemy.request_historical_candles(client, "EUR/USD",
            interval: 1,
            from: ~U[2026-07-22 10:00:00Z],
            to: ~U[2026-07-22 12:00:00Z]
          )
        end)

      request = await_message(&(Parser.extract_msg_type(&1) == "V"))
      {"262", request_id} = List.keyfind(Parser.split_fields(request), "262", 0)

      FakeFixServer.send_raw(
        ctx.server,
        FakeFixServer.build("Y", [{"262", request_id}, {"58", "HISTORY UNAVAILABLE"}])
      )

      assert {:error, {:rejected, "HISTORY UNAVAILABLE"}} = Task.await(task, 5_000)
    end
  end

  defp quote_for(symbol, bid, ask) do
    FakeFixServer.build("X", [
      {"268", "2"},
      {"279", "1"},
      {"269", "0"},
      {"55", symbol},
      {"270", bid},
      {"279", "1"},
      {"269", "1"},
      {"55", symbol},
      {"270", ask}
    ])
  end

  defp candle_snapshot(request_id, date, time, [open, high, low, close]) do
    entries =
      Enum.flat_map([open, high, low, close], fn px ->
        [{"269", "0"}, {"270", px}, {"272", date}, {"273", time}]
      end)

    FakeFixServer.build("W", [{"262", request_id}, {"55", "EUR/USD"}, {"268", "4"} | entries])
  end

  defp insert_poison_field(message) do
    <<"8=FIX.4.4", @soh, "9=", _rest::binary>> = message
    [_old_frame, after_length] = :binary.split(message, <<@soh, "35=">>)
    body = "35=" <> after_length
    body_without_trailer = binary_part(body, 0, byte_size(body) - 7)
    poisoned_body = body_without_trailer <> "notagvalue" <> @soh
    framed = "8=FIX.4.4#{@soh}9=#{byte_size(poisoned_body)}#{@soh}#{poisoned_body}"
    framed <> "10=#{Parser.calculate_checksum(framed)}#{@soh}"
  end
end

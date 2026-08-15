defmodule FxcmAlchemy.ClosePositionTest do
  @moduledoc """
  Closing a position names the leg it closes.

  FXCM legs by `9041`, so an order that only offsets size closes whichever leg
  the broker picks, which is not necessarily the one that was asked for. The
  order carries `77=C` and the leg's own id, and this asserts that on the bytes
  that reach the venue rather than on the call that produced them.
  """

  use ExUnit.Case, async: false

  alias FixAlchemy.Parser
  alias FixAlchemy.SessionSupervisor
  alias FxcmAlchemy.FakeFixServer

  @spec_file Path.join([__DIR__, "..", "..", "priv", "specs", "FIX44.xml"])
  @soh <<1>>

  setup do
    {:ok, server} = FakeFixServer.start_link(self())
    connection_id = "close_#{System.unique_integer([:positive])}"

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
      handlers: [FxcmAlchemy.Session, FxcmAlchemy.MarketData, FxcmAlchemy.Portfolio]
    ]

    start_supervised!({SessionSupervisor, opts}, restart: :temporary)
    assert_receive :fix_server_connected, 2000

    {:ok, connection_id: connection_id, server: server}
  end

  defp client_pid(connection_id) do
    [{pid, _}] = Registry.lookup(FixAlchemy.Registry, {connection_id, :trading})
    pid
  end

  defp portfolio_pid(connection_id) do
    [{pid, _}] = Registry.lookup(FixAlchemy.Registry, {connection_id, :trading, :portfolio})
    pid
  end

  defp build_message(msg_type, fields) do
    body =
      ([{"35", msg_type}, {"49", "FAKE"}, {"56", "CLIENT"}] ++ fields)
      |> Enum.map_join(@soh, fn {tag, value} -> "#{tag}=#{value}" end)

    body = body <> @soh
    framed = "8=FIX.4.4#{@soh}9=#{byte_size(body)}#{@soh}#{body}"
    framed <> "10=#{Parser.calculate_checksum(framed)}#{@soh}"
  end

  defp hold(connection_id, fields) do
    send(portfolio_pid(connection_id), {:fix, "AP", build_message("AP", fields), %{}})
    FixAlchemy.Portfolio.get_positions(connection_id, :trading)
  end

  defp hold_long(connection_id) do
    hold(connection_id, [
      {"55", "EUR/USD"},
      {"9041", "41372232"},
      {"704", "1000"},
      {"730", "1.0850"}
    ])
  end

  defp hold_short(connection_id) do
    hold(connection_id, [
      {"55", "GBP/JPY"},
      {"9041", "41372999"},
      {"705", "2000"},
      {"730", "214.874"}
    ])
  end

  defp await_order(timeout \\ 3000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_order(deadline)
  end

  defp do_await_order(deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:server_received, message} ->
        if Parser.extract_msg_type(message) == "D" do
          message |> Parser.split_fields() |> Map.new()
        else
          do_await_order(deadline)
        end
    after
      remaining -> flunk("no NewOrderSingle (35=D) reached the venue")
    end
  end

  test "the close names the leg it closes", %{connection_id: connection_id} do
    hold_long(connection_id)

    :ok = FxcmAlchemy.close_position_by_id(client_pid(connection_id), "41372232", nil)

    order = await_order()

    assert order["9041"] == "41372232",
           "without FXCMPosID the broker closes a leg of its own choosing"
  end

  test "the close is marked as closing rather than opening", %{connection_id: connection_id} do
    hold_long(connection_id)

    :ok = FxcmAlchemy.close_position_by_id(client_pid(connection_id), "41372232", nil)

    assert await_order()["77"] == "C"
  end

  test "a long is closed by a sell of its own size", %{connection_id: connection_id} do
    hold_long(connection_id)

    :ok = FxcmAlchemy.close_position_by_id(client_pid(connection_id), "41372232", nil)

    order = await_order()

    assert order["54"] == "2"
    assert order["38"] == "1000"
    assert order["55"] == "EUR/USD"
  end

  test "a short is closed by a buy of its own size", %{connection_id: connection_id} do
    hold_short(connection_id)

    :ok = FxcmAlchemy.close_position_by_id(client_pid(connection_id), "41372999", nil)

    order = await_order()

    assert order["54"] == "1"
    assert order["38"] == "2000"
    assert order["9041"] == "41372999"
  end

  test "closing part of a position sends only that part", %{connection_id: connection_id} do
    hold_long(connection_id)

    :ok = FxcmAlchemy.close_position_by_id(client_pid(connection_id), "41372232", 400)

    order = await_order()

    assert order["38"] == "400"
    assert order["9041"] == "41372232"
    assert order["77"] == "C"
  end

  test "a position the session does not hold is not closed", %{connection_id: connection_id} do
    assert FxcmAlchemy.close_position_by_id(client_pid(connection_id), "nosuch", nil) ==
             {:error, :position_not_found}
  end

  test "a quantity beyond anything sane is refused rather than sent", %{
    connection_id: connection_id
  } do
    hold_long(connection_id)

    assert FxcmAlchemy.close_position_by_id(
             client_pid(connection_id),
             "41372232",
             500_000_000
           ) == {:error, :quantity_too_large}
  end
end

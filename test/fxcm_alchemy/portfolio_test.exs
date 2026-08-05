defmodule FxcmAlchemy.PortfolioTest do
  use ExUnit.Case

  alias FixAlchemy.Portfolio

  @spec_file Path.join([__DIR__, "..", "..", "priv", "specs", "FIX44.xml"])
  @soh <<1>>

  setup do
    connection_id = "portfolio_#{System.unique_integer([:positive])}"

    opts = [
      connection_id: connection_id,
      session_name: :trading,
      account: "ACC1",
      spec_file: @spec_file
    ]

    start_supervised!({FxcmAlchemy.Portfolio, opts})
    {:ok, connection_id: connection_id}
  end

  defp build_message(msg_type, fields) do
    body =
      ([{"35", msg_type}, {"49", "FAKE"}, {"56", "CLIENT"}] ++ fields)
      |> Enum.map(fn {tag, value} -> "#{tag}=#{value}" end)
      |> Enum.join(@soh)

    body = body <> @soh
    framed = "8=FIX.4.4#{@soh}9=#{byte_size(body)}#{@soh}#{body}"
    framed <> "10=#{FixAlchemy.Parser.calculate_checksum(framed)}#{@soh}"
  end

  defp portfolio_pid(connection_id) do
    [{pid, _}] = Registry.lookup(FixAlchemy.Registry, {connection_id, :trading, :portfolio})
    pid
  end

  defp feed(connection_id, msg_type, fields) do
    send(portfolio_pid(connection_id), {:fix, msg_type, build_message(msg_type, fields), %{}})
  end

  defp dispatch_and_sync(connection_id, msg_type, fields) do
    feed(connection_id, msg_type, fields)
    Portfolio.get_positions(connection_id, :trading)
  end

  describe "position reports (AP)" do
    test "stores a long position keyed by position id", %{connection_id: connection_id} do
      positions =
        dispatch_and_sync(connection_id, "AP", [
          {"55", "EUR/USD"},
          {"721", "P1"},
          {"704", "1000"},
          {"730", "1.0850"}
        ])

      assert %{"P1" => position} = positions
      assert position.symbol == "EUR/USD"
      assert position.size == "1000"
      assert position.side == :buy
    end

    test "removes a position when quantity reaches zero", %{connection_id: connection_id} do
      dispatch_and_sync(connection_id, "AP", [{"55", "EUR/USD"}, {"721", "P1"}, {"704", "1000"}])

      positions =
        dispatch_and_sync(connection_id, "AP", [{"55", "EUR/USD"}, {"721", "P1"}, {"704", "0"}])

      assert positions == %{}
    end
  end

  describe "execution reports (8)" do
    test "caches an active order and drops it once filled", %{connection_id: connection_id} do
      feed(connection_id, "8", [
        {"11", "ORD1"},
        {"39", "0"},
        {"150", "0"},
        {"151", "1000"},
        {"55", "EUR/USD"},
        {"54", "1"}
      ])

      assert %{"ORD1" => _order} = Portfolio.get_orders(connection_id, :trading)

      feed(connection_id, "8", [
        {"11", "ORD1"},
        {"39", "2"},
        {"150", "F"},
        {"151", "0"},
        {"14", "1000"},
        {"6", "1.0850"},
        {"55", "EUR/USD"},
        {"54", "1"}
      ])

      assert Portfolio.get_orders(connection_id, :trading) == %{}
    end
  end

  describe "cancel confirmation (8)" do
    test "removes the tracked order by OrigClOrdID when the confirmation carries a new ClOrdID",
         %{connection_id: connection_id} do
      feed(connection_id, "8", [
        {"11", "AUD/NZD_1"},
        {"37", "79663532"},
        {"39", "0"},
        {"150", "0"},
        {"151", "1000"},
        {"55", "AUD/NZD"},
        {"54", "1"}
      ])

      assert %{"AUD/NZD_1" => _order} = Portfolio.get_orders(connection_id, :trading)

      feed(connection_id, "8", [
        {"11", "cxl_1"},
        {"41", "AUD/NZD_1"},
        {"37", "79663532"},
        {"39", "4"},
        {"150", "4"},
        {"151", "0"},
        {"55", "AUD/NZD"},
        {"54", "1"}
      ])

      assert Portfolio.get_orders(connection_id, :trading) == %{}
    end
  end

  describe "collateral (BA)" do
    test "stores collateral and account from a collateral report", %{
      connection_id: connection_id
    } do
      feed(connection_id, "BA", [{"1", "DISCOVERED_ACC"}, {"922", "10000"}])

      collateral = Portfolio.get_collateral(connection_id, :trading)

      assert collateral.account == "DISCOVERED_ACC"

      summary = Portfolio.get_account_summary(connection_id, :trading)
      assert summary.account_id == "DISCOVERED_ACC"
      assert summary.balance == 10_000.0
    end

    test "a report is filed under its own account, and the selected one is summarized", %{
      connection_id: connection_id
    } do
      feed(connection_id, "BA", [{"1", "ACC_A"}, {"922", "10000"}])
      feed(connection_id, "BA", [{"1", "ACC_B"}, {"922", "25000"}])

      assert Portfolio.list_accounts(connection_id, :trading) == ["ACC_A", "ACC_B"]

      summary = Portfolio.get_account_summary(connection_id, :trading)
      assert summary.account_id == "ACC_A"
      assert summary.balance == 10_000.0

      assert Portfolio.set_active_account(connection_id, :trading, "ACC_B") == :ok

      summary = Portfolio.get_account_summary(connection_id, :trading)
      assert summary.account_id == "ACC_B"
      assert summary.balance == 25_000.0
      assert Portfolio.get_collateral(connection_id, :trading).account == "ACC_B"
    end
  end
end

defmodule FxcmAlchemy.AccountPnLTest do
  @moduledoc """
  The account summary carries both halves of P&L.

  Realized P&L is accrued by the portfolio, which is what sees positions close.
  Unrealized P&L is priced by the tracker, which is what sees quotes. The
  summary a reader gets holds the two and their sum.
  """

  use ExUnit.Case, async: true

  alias FxcmAlchemy.Portfolio

  describe "the portfolio's summary" do
    test "carries what has been realized so far" do
      state = %{
        collaterals: %{"ACC1" => %{account: "ACC1", end_cash: "10000", currency: "USD"}},
        active_account: "ACC1",
        default_account: "ACC1",
        accounts: ["ACC1"],
        realized_pnl: 42.0
      }

      summary = Portfolio.build_account_summary(state)

      assert summary.realized_pnl == 42.0
    end

    test "totals realized with the unrealized it knows of" do
      state = %{
        collaterals: %{"ACC1" => %{account: "ACC1", end_cash: "10000", currency: "USD"}},
        active_account: "ACC1",
        default_account: "ACC1",
        accounts: ["ACC1"],
        realized_pnl: 42.0
      }

      summary = Portfolio.build_account_summary(state)

      assert summary.total_pnl == summary.realized_pnl + summary.unrealized_pnl
    end

    test "a venue that has reported no collateral still states realized" do
      state = %{
        collaterals: %{},
        active_account: "ACC1",
        default_account: "ACC1",
        accounts: ["ACC1"],
        realized_pnl: 7.5
      }

      assert Portfolio.build_account_summary(state).realized_pnl == 7.5
    end
  end
end

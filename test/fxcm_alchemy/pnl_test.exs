defmodule FxcmAlchemy.PnLTest do
  use ExUnit.Case, async: true

  alias FxcmAlchemy.PnL

  @prices %{
    "USD/JPY" => %{bid: 163.10, ask: 163.11},
    "GBP/JPY" => %{bid: 218.14, ask: 218.15},
    "GBP/USD" => %{bid: 1.2700, ask: 1.2701},
    "EUR/USD" => %{bid: 1.1400, ask: 1.1401}
  }

  describe "position_pnl/3 in a USD account" do
    test "quote currency is the account currency (EUR/USD)" do
      position = %{symbol: "EUR/USD", side: :buy, entry_price: 1.1400, quantity: 10_000}
      prices = Map.put(@prices, "EUR/USD", %{bid: 1.1450, ask: 1.1451})

      assert PnL.position_pnl(position, prices, "USD") == 50.0
    end

    test "base currency is the account currency (USD/JPY) converts quote to base" do
      position = %{symbol: "USD/JPY", side: :buy, entry_price: 163.00, quantity: 1000}

      pnl = PnL.position_pnl(position, @prices, "USD")

      assert_in_delta pnl, (163.10 - 163.00) * 1000 / 163.10, 0.01
    end

    test "cross pair converts via the account/quote pair (GBP/JPY)" do
      position = %{symbol: "GBP/JPY", side: :buy, entry_price: 218.00, quantity: 1000}

      pnl = PnL.position_pnl(position, @prices, "USD")

      assert_in_delta pnl, (218.14 - 218.00) * 1000 / 163.10, 0.01
    end

    test "cross pair converts via the inverse quote/account pair" do
      position = %{symbol: "EUR/GBP", side: :buy, entry_price: 0.8600, quantity: 10_000}
      prices = Map.put(@prices, "EUR/GBP", %{bid: 0.8650, ask: 0.8651})

      pnl = PnL.position_pnl(position, prices, "USD")

      assert_in_delta pnl, (0.8650 - 0.8600) * 10_000 * 1.2700, 0.01
    end

    test "short position gains when price falls" do
      position = %{symbol: "GBP/JPY", side: :sell, entry_price: 218.20, quantity: 1000}

      pnl = PnL.position_pnl(position, @prices, "USD")

      assert pnl > 0
    end

    test "returns zero when no price is available yet" do
      position = %{symbol: "AUD/NZD", side: :buy, entry_price: 1.20, quantity: 1000}
      assert PnL.position_pnl(position, @prices, "USD") == 0.0
    end

    test "returns zero when the conversion pair is missing" do
      position = %{symbol: "GBP/JPY", side: :buy, entry_price: 218.00, quantity: 1000}
      prices = %{"GBP/JPY" => %{bid: 218.14, ask: 218.15}}

      assert PnL.position_pnl(position, prices, "USD") == 0.0
    end

    test "returns zero instead of crashing when the mark side is nil or empty" do
      sell = %{symbol: "EUR/USD", side: :sell, entry_price: 1.14, quantity: 1000}
      buy = %{symbol: "EUR/USD", side: :buy, entry_price: 1.14, quantity: 1000}

      assert PnL.position_pnl(sell, %{"EUR/USD" => %{bid: 1.1386, ask: nil}}, "USD") == 0.0
      assert PnL.position_pnl(buy, %{"EUR/USD" => %{bid: nil, ask: 1.1387}}, "USD") == 0.0
      assert PnL.position_pnl(sell, %{"EUR/USD" => %{bid: 1.1386}}, "USD") == 0.0
    end
  end

  describe "position_pnl/3 in a JPY account" do
    test "quote currency is the account currency (USD/JPY)" do
      position = %{symbol: "USD/JPY", side: :buy, entry_price: 163.00, quantity: 1000}

      assert_in_delta PnL.position_pnl(position, @prices, "JPY"), (163.10 - 163.00) * 1000, 0.01
    end
  end
end

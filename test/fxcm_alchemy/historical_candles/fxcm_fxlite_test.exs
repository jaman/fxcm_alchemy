defmodule FxcmAlchemy.HistoricalCandles.FxcmFxliteTest do
  use ExUnit.Case, async: true

  alias FxcmAlchemy.HistoricalCandles.FxcmFxlite

  describe "symbol_candidates/1" do
    test "a slashed FX pair also tries the unslashed form" do
      assert FxcmFxlite.symbol_candidates("EUR/USD") == ["EUR/USD", "EURUSD"]
    end

    test "an unslashed six-letter FX pair also tries the slashed form" do
      assert FxcmFxlite.symbol_candidates("EURUSD") == ["EURUSD", "EUR/USD"]
    end

    test "a non-FX symbol is tried as-is only" do
      assert FxcmFxlite.symbol_candidates("WHEATF") == ["WHEATF"]
      assert FxcmFxlite.symbol_candidates("6758.jp") == ["6758.jp"]
    end
  end
end

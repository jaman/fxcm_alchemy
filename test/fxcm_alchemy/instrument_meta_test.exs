defmodule FxcmAlchemy.InstrumentMetaTest do
  @moduledoc """
  FXCM describes a symbol in its own tag range: FXCMSymPointSize (`9002`), which
  FIX 4.4 has no equivalent for, and FXCMSymMarginRatio (`9006`), which duplicates
  the standard `MarginRatio` (898). Reading them belongs to the FXCM adapter —
  a venue's private tags are not the FIX protocol's.
  """

  use ExUnit.Case, async: true

  alias FxcmAlchemy.MarketData

  test "reads the point size FXCM publishes, which the standard has no field for" do
    meta = MarketData.instrument_meta(%{symbol: "EUR/USD", fxcm_sym_point_size: "0.0001"})

    assert meta.point_size == 0.0001
  end

  test "reads the margin ratio FXCM publishes" do
    meta = MarketData.instrument_meta(%{symbol: "EUR/USD", fxcm_sym_margin_ratio: "0.02"})

    assert meta.margin_rate == 0.02
  end

  test "falls back to the standard field where FXCM leaves its own empty" do
    meta = MarketData.instrument_meta(%{symbol: "EUR/USD", margin_ratio: "0.0333"})

    assert meta.margin_rate == 0.0333
  end

  test "prefers FXCM's own field when both are present" do
    meta =
      MarketData.instrument_meta(%{
        symbol: "EUR/USD",
        margin_ratio: "0.0333",
        fxcm_sym_margin_ratio: "0.02"
      })

    assert meta.margin_rate == 0.02
  end

  test "a requirement quoted per contract is not read as a fraction" do
    meta = MarketData.instrument_meta(%{symbol: "EUR/USD", fxcm_sym_margin_ratio: "33.33"})

    refute Map.has_key?(meta, :margin_rate)
  end

  test "a symbol the venue only named carries nothing" do
    assert MarketData.instrument_meta(%{symbol: "EUR/USD"}) == %{}
  end
end

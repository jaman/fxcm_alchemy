defmodule FxcmAlchemy.MarketData do
  @moduledoc """
  FXCM's per-session market data subscriber.

  Extends the plain-FIX `FixAlchemy.MarketData` with FXCM's historical
  MarketDataRequest fields: the FXCMTimingInterval (`9011`) and the
  FXCMStartDate/Time and FXCMEndDate/Time window (`9012`–`9015`), and with the
  symbol details FXCM publishes in its own tag range. Streaming quotes, candle
  accumulation and the security list itself all come from the base.
  """

  use FixAlchemy.MarketData

  @doc """
  FXCM's security list entries, which describe a symbol in its own tags.

  FXCMSymPointSize (`9002`) has no standard equivalent in FIX 4.4 at all.
  FXCMSymMarginRatio (`9006`) does — `MarginRatio` (898), which FXCM's own spec
  also carries in FinancingDetails — but FXCM populates its own field, so both
  are read and the standard one stands where FXCM leaves 9006 empty.
  """
  @impl FixAlchemy.MarketData
  def instrument_meta(entry) do
    entry
    |> FixAlchemy.MarketData.standard_instrument_meta()
    |> Map.merge(point_size_meta(entry))
    |> Map.merge(FixAlchemy.MarketData.margin_rate_meta(Map.get(entry, :fxcm_sym_margin_ratio)))
  end

  defp point_size_meta(entry) do
    case Float.parse(Map.get(entry, :fxcm_sym_point_size, "")) do
      {point_size, _rest} when point_size > 0 -> %{point_size: point_size}
      _absent_or_invalid -> %{}
    end
  end

  @impl FixAlchemy.MarketData
  def historical_request_fields(request_id, symbol, opts) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.fetch!(opts, :to)

    [
      {262, request_id},
      {263, "0"},
      {264, "1"},
      {267, "2"},
      {269, "0"},
      {269, "1"},
      {146, "1"},
      {55, symbol},
      {9011, Keyword.fetch!(opts, :interval)},
      {9012, Calendar.strftime(from, "%Y%m%d")},
      {9013, Calendar.strftime(from, "%H:%M:%S")},
      {9014, Calendar.strftime(to, "%Y%m%d")},
      {9015, Calendar.strftime(to, "%H:%M:%S")}
    ]
  end
end

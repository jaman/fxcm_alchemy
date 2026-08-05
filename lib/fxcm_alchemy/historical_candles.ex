defmodule FxcmAlchemy.HistoricalCandles do
  @moduledoc """
  Behaviour for historical candle sources on FIX connections.

  A connection selects its source via the `historical_source` config field: the
  FXCM CandleData archive fetcher (default, published with a multi-week lag),
  `fxcm_fxlite` for current data via the native fxlite platform protocol,
  `none`, or `custom` with `historical_module` naming any module implementing
  this behaviour.
  """

  @type candle :: %{
          time: integer(),
          open: float(),
          high: float(),
          low: float(),
          close: float()
        }

  @doc """
  Fetch candles for a symbol.

  ## Options

    * `:timeframe` - Candle size, e.g. `"1m"`, `"1h"` (default: `"1m"`)
    * `:count` - Maximum candles to return (default: 500)
    * `:before` - When set, return the candles immediately preceding this
      `DateTime` instead of the most recent ones. Chart panning uses this to
      page further back through history.
    * `:config` - The connection's `backend_config`
    * `:connection_id` - The connection requesting the candles
  """
  @callback fetch_candles(symbol :: String.t(), opts :: keyword()) ::
              {:ok, [candle()]} | {:error, term()}

  @spec resolve(map()) :: [module()]
  def resolve(config) when is_map(config) do
    case Map.get(config, "historical_source", "fxcm_candledata") do
      "none" -> []
      "custom" -> resolve_custom(Map.get(config, "historical_module"))
      "fxcm_fxlite" -> [FxcmAlchemy.HistoricalCandles.FxcmFxlite]
      "fix_session" -> [FxcmAlchemy.HistoricalCandles.FixSession]
      _default -> [FxcmAlchemy.HistoricalCandles.FxcmCandleData]
    end
  end

  defp resolve_custom(module_name) when is_binary(module_name) and module_name != "" do
    module = Module.concat([module_name])

    if Code.ensure_loaded?(module) and function_exported?(module, :fetch_candles, 2) do
      [module]
    else
      []
    end
  end

  defp resolve_custom(_module_name), do: []
end

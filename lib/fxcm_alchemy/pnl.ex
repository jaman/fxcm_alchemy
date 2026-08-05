defmodule FxcmAlchemy.PnL do
  @moduledoc """
  Unrealized P&L for FX positions, expressed in the account's base currency.

  A position in `XXX/YYY` accrues P&L in the quote currency `YYY`; converting
  to the account currency requires the right cross rate:

    * quote is the account currency → no conversion
    * base is the account currency → divide by the pair's own current rate
    * otherwise → convert via `ACC/YYY` (divide) or `YYY/ACC` (multiply),
      whichever the price map provides

  Symbols use the platform's slashed format (`"GBP/JPY"`), which is also how
  the price map is keyed.
  """

  @type price :: %{bid: number(), ask: number()}
  @type prices :: %{String.t() => price()}
  @type position :: %{
          symbol: String.t(),
          side: :buy | :sell,
          entry_price: number(),
          quantity: number()
        }

  @spec position_pnl(position(), prices(), String.t()) :: float()
  def position_pnl(%{symbol: symbol} = position, prices, base_currency) do
    with %{} = price <- Map.get(prices, symbol),
         entry when is_number(entry) <- position[:entry_price],
         quantity when is_number(quantity) <- position[:quantity],
         current when is_number(current) and current > 0 <- mark_price(price, position.side) do
      pnl_quote = price_diff(current, entry, position.side) * quantity

      case quote_to_base_rate(symbol, base_currency, current, prices) do
        nil -> 0.0
        rate -> Float.round(pnl_quote * rate, 4)
      end
    else
      _incomplete -> 0.0
    end
  end

  defp mark_price(%{bid: bid}, :buy), do: bid
  defp mark_price(%{ask: ask}, :sell), do: ask
  defp mark_price(_price, _side), do: nil

  defp price_diff(current, entry, :buy), do: current - entry
  defp price_diff(current, entry, :sell), do: entry - current

  defp quote_to_base_rate(symbol, base_currency, current_price, prices) do
    {base_ccy, quote_ccy} = currencies(symbol)

    cond do
      quote_ccy == base_currency -> 1.0
      base_ccy == base_currency -> 1.0 / current_price
      true -> cross_rate(base_currency, quote_ccy, prices)
    end
  end

  defp cross_rate(base_currency, quote_ccy, prices) do
    direct = Map.get(prices, "#{base_currency}/#{quote_ccy}")
    inverse = Map.get(prices, "#{quote_ccy}/#{base_currency}")

    cond do
      is_number(direct[:bid]) and direct[:bid] > 0 -> 1.0 / direct[:bid]
      is_number(inverse[:bid]) and inverse[:bid] > 0 -> inverse[:bid]
      true -> nil
    end
  end

  defp currencies(symbol) do
    case String.split(symbol, "/") do
      [base, quote] -> {base, quote}
      _no_separator -> {String.slice(symbol, 0, 3), String.slice(symbol, -3, 3)}
    end
  end
end

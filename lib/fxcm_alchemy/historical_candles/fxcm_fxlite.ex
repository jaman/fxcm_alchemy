defmodule FxcmAlchemy.HistoricalCandles.FxcmFxlite do
  @moduledoc """
  Historical candles from the FXCM fxlite trading platform.

  Uses `FxliteAlchemy` to log into the same PDAS backend that powers the
  FXCM web platform and requests candle history directly, so data is current.
  Sessions are pooled per server/user and kept logged in between fetches.

  Connection config keys: `fxlite_username` / `fxlite_password` (default to
  the FIX credentials), `fxlite_url` (default `https://www.fxcorporate.com`)
  and `fxlite_connection` (default `Demo`).
  """

  @behaviour FxcmAlchemy.HistoricalCandles

  @doc false
  def __historical_source__, do: true

  @doc false
  def source_config,
    do: %{id: :fxcm_fxlite, label: "FXCM fxlite platform (current)", backends: [:fxcm]}

  require Logger

  @default_url "https://www.fxcorporate.com"
  @default_connection "Demo"
  @window_margin_factor 2
  @window_margin_seconds 3 * 86_400

  @currencies ~w(AUD CAD CHF CNH CZK DKK EUR GBP HKD HUF ILS JPY MXN NOK NZD PLN SEK SGD TRY USD ZAR)

  @impl true
  def fetch_candles(symbol, opts) do
    config = Keyword.get(opts, :config, %{})
    timeframe = Keyword.get(opts, :timeframe, "1m")
    count = Keyword.get(opts, :count, 500)

    with :ok <- ensure_available(),
         {:ok, session_opts} <- validate_session_opts(session_opts(config)),
         {:ok, session} <- FxliteAlchemy.SessionPool.checkout(session_opts) do
      to = Keyword.get(opts, :before) || DateTime.utc_now()
      from = window_from(timeframe, count, to)

      fetch_first_available(session, symbol_candidates(symbol), timeframe, from, to, count)
    end
  end

  @doc """
  Symbols to try, in order. FX pairs are tried both slashed and unslashed, since
  brokers disagree on the format (`"EUR/USD"` vs `"EURUSD"`) and the historical
  engine only finds a match under its own convention.
  """
  @spec symbol_candidates(String.t()) :: [String.t()]
  def symbol_candidates(symbol) do
    cond do
      String.contains?(symbol, "/") ->
        Enum.uniq([symbol, String.replace(symbol, "/", "")])

      currency_pair?(symbol) ->
        <<base::binary-3, counter::binary-3>> = symbol
        Enum.uniq([symbol, base <> "/" <> counter])

      true ->
        [symbol]
    end
  end

  defp currency_pair?(<<base::binary-3, counter::binary-3>>) do
    String.upcase(base) in @currencies and String.upcase(counter) in @currencies
  end

  defp currency_pair?(_symbol), do: false

  defp fetch_first_available(session, candidates, timeframe, from, to, count) do
    Enum.reduce_while(candidates, {:error, :no_data}, fn candidate, _last ->
      case FxliteAlchemy.get_candles(session, candidate, timeframe,
             from: from,
             to: to,
             quotes_count: count
           ) do
        {:ok, [_ | _] = candles} -> {:halt, {:ok, Enum.map(candles, &to_chart_candle/1)}}
        {:ok, []} -> {:cont, {:error, :no_data}}
        {:error, _reason} = error -> {:cont, error}
      end
    end)
  end

  @spec to_chart_candle(FxliteAlchemy.PriceHistory.Candle.t()) ::
          FxcmAlchemy.HistoricalCandles.candle()
  def to_chart_candle(candle) do
    %{
      time: DateTime.to_unix(candle.timestamp),
      open: candle.bid_open,
      high: candle.bid_high,
      low: candle.bid_low,
      close: candle.bid_close
    }
  end

  @spec window_from(String.t(), pos_integer(), DateTime.t()) :: DateTime.t()
  def window_from(timeframe, count, now) do
    span = count * FxliteAlchemy.PriceHistory.timeframe_seconds(timeframe)
    DateTime.add(now, -(span * @window_margin_factor + @window_margin_seconds), :second)
  end

  @spec session_opts(map()) :: keyword()
  def session_opts(config) do
    [
      url: setting(config, "fxlite_url", @default_url),
      connection_name: setting(config, "fxlite_connection", @default_connection),
      username: setting(config, "fxlite_username", Map.get(config, "username", "")),
      password: setting(config, "fxlite_password", Map.get(config, "password", ""))
    ]
  end

  defp validate_session_opts(opts) do
    if opts[:username] == "" or opts[:password] == "" do
      {:error, :missing_fxlite_credentials}
    else
      {:ok, opts}
    end
  end

  defp ensure_available do
    if Code.ensure_loaded?(FxliteAlchemy) do
      :ok
    else
      Logger.warning("fxcm_fxlite historical source selected but fxlite_alchemy is not available")
      {:error, :fxlite_alchemy_unavailable}
    end
  end

  defp setting(config, key, default) do
    case Map.get(config, key, "") do
      "" -> default
      value -> value
    end
  end
end

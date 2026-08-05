defmodule FxcmAlchemy.HistoricalCandles.FixSession do
  @moduledoc """
  Historical candles over the connection's own authenticated FIX session.

  Issues a MarketDataRequest snapshot with FXCM's timing-interval and
  date-window fields (FXCMTimingInterval 9011, FXCMStartDate/Time 9012/9013,
  FXCMEndDate/Time 9014/9015); the venue answers with one
  MarketDataSnapshotFullRefresh per candle. Because the session is logged in,
  this returns current data.

  FXCM's interval enum has no 4h value, so 4h is served by aggregating
  hourly candles.
  """
  @behaviour FxcmAlchemy.HistoricalCandles

  @doc false
  def __historical_source__, do: true

  @doc false
  def source_config, do: %{id: :fix_session, label: "FIX session (native)"}

  @doc false
  def applies_to?(%{module: module}) when is_atom(module) and not is_nil(module),
    do: function_exported?(module, :handlers, 0) and function_exported?(module, :defer_ready?, 0)

  def applies_to?(_backend), do: false

  @weekend_pad_factor 1.5
  @weekend_pad_seconds 72 * 3600

  @impl true
  def fetch_candles(symbol, opts) do
    with {:ok, {interval_enum, bucket_seconds, agg_factor}} <-
           interval_spec(Keyword.get(opts, :timeframe, "1m")),
         {:ok, pid} <- session_pid(Keyword.get(opts, :connection_id)) do
      count = Keyword.get(opts, :count, 500)
      {from, to} = request_window_seconds(bucket_seconds, count * agg_factor, DateTime.utc_now())

      case FxcmAlchemy.request_historical_candles(pid, symbol,
             interval: interval_enum,
             from: from,
             to: to
           ) do
        {:ok, candles} ->
          {:ok,
           candles
           |> aggregate(agg_factor)
           |> Enum.take(-count)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec interval_spec(String.t()) ::
          {:ok, {pos_integer(), pos_integer(), pos_integer()}} | {:error, :unsupported_timeframe}
  def interval_spec("1m"), do: {:ok, {1, 60, 1}}
  def interval_spec("5m"), do: {:ok, {2, 300, 1}}
  def interval_spec("15m"), do: {:ok, {3, 900, 1}}
  def interval_spec("30m"), do: {:ok, {4, 1800, 1}}
  def interval_spec("1h"), do: {:ok, {5, 3600, 1}}
  def interval_spec("4h"), do: {:ok, {5, 3600, 4}}
  def interval_spec("1d"), do: {:ok, {6, 86_400, 1}}
  def interval_spec(_timeframe), do: {:error, :unsupported_timeframe}

  @spec request_window(String.t(), pos_integer(), DateTime.t()) :: {DateTime.t(), DateTime.t()}
  def request_window(timeframe, count, now) do
    {:ok, {_enum, bucket_seconds, agg_factor}} = interval_spec(timeframe)
    request_window_seconds(bucket_seconds, count * agg_factor, now)
  end

  defp request_window_seconds(bucket_seconds, buckets, now) do
    span = trunc(bucket_seconds * buckets * @weekend_pad_factor) + @weekend_pad_seconds
    {DateTime.add(now, -span, :second), now}
  end

  @spec aggregate([FxcmAlchemy.HistoricalCandles.candle()], pos_integer()) ::
          [FxcmAlchemy.HistoricalCandles.candle()]
  def aggregate(candles, 1), do: candles

  def aggregate(candles, factor) do
    bucket_span =
      case candles do
        [%{time: t1}, %{time: t2} | _rest] -> abs(t2 - t1) * factor
        _short -> 3600 * factor
      end

    candles
    |> Enum.group_by(fn candle -> div(candle.time, bucket_span) * bucket_span end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {bucket_time, members} ->
      members = Enum.sort_by(members, & &1.time)

      %{
        time: bucket_time,
        open: List.first(members).open,
        high: members |> Enum.map(& &1.high) |> Enum.max(),
        low: members |> Enum.map(& &1.low) |> Enum.min(),
        close: List.last(members).close
      }
    end)
  end

  defp session_pid(nil), do: {:error, :no_connection}

  defp session_pid(connection_id) do
    with {:ok, name} <- resolve_market_data(connection_id),
         [{pid, _}] <- Registry.lookup(FixAlchemy.Registry, {connection_id, name}) do
      {:ok, pid}
    else
      _no_session -> {:error, :no_session}
    end
  end

  defp resolve_market_data(connection_id) do
    FixAlchemy.SessionDirectory.resolve(connection_id, :market_data)
  end
end

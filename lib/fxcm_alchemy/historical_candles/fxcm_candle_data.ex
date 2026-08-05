defmodule FxcmAlchemy.HistoricalCandles.FxcmCandleData do
  @moduledoc """
  Historical candles from FXCM's public CandleData repository
  (https://candledata.fxcorporate.com).

  Weekly m1 CSVs are downloaded once into a local cache (immutable past
  weeks are kept; the current week refreshes after a short TTL) and
  aggregated to the requested timeframe with DuckDB.
  """
  @behaviour FxcmAlchemy.HistoricalCandles

  @doc false
  def __historical_source__, do: true

  @doc false
  def source_config,
    do: %{id: :fxcm_candledata, label: "FXCM CandleData (public, delayed)"}

  require Logger

  @base_url "https://candledata.fxcorporate.com"
  @minutes_per_week 5 * 24 * 60
  @max_weeks 8
  @publication_lag_weeks 12
  @max_probe_weeks 16
  @current_week_ttl_seconds 300
  @miss_ttl_seconds 3600

  @impl true
  def fetch_candles(symbol, opts) do
    timeframe = Keyword.get(opts, :timeframe, "1m")
    count = Keyword.get(opts, :count, 500)
    before = Keyword.get(opts, :before)

    files =
      symbol
      |> weekly_urls(anchor_date(before), probe_window(timeframe, count))
      |> Enum.map(&cached_download/1)
      |> Enum.filter(&(&1 != nil))
      |> Enum.take(weeks_needed(timeframe, count))

    case files do
      [] -> {:error, :no_data}
      files -> query_candles(files, timeframe, count, before)
    end
  end

  @spec anchor_date(DateTime.t() | nil) :: Date.t()
  def anchor_date(nil), do: Date.utc_today()
  def anchor_date(%DateTime{} = before), do: DateTime.to_date(before)

  @spec probe_window(String.t(), pos_integer()) :: pos_integer()
  def probe_window(timeframe, count) do
    min(weeks_needed(timeframe, count) + @publication_lag_weeks, @max_probe_weeks)
  end

  @spec instrument_code(String.t()) :: String.t()
  def instrument_code(symbol) do
    String.replace(symbol, ~r/[^A-Za-z0-9]/, "")
  end

  @spec week_of_year(Date.t()) :: pos_integer()
  def week_of_year(%Date{} = date) do
    date |> Date.day_of_year() |> Kernel./(7) |> ceil()
  end

  @spec recent_year_weeks(Date.t(), pos_integer()) :: [{pos_integer(), pos_integer()}]
  def recent_year_weeks(%Date{} = date, weeks) do
    {date.year, week_of_year(date)}
    |> Stream.iterate(&previous_week/1)
    |> Enum.take(weeks)
  end

  defp previous_week({year, 1}), do: {year - 1, weeks_in_year(year - 1)}
  defp previous_week({year, week}), do: {year, week - 1}

  defp weeks_in_year(year) do
    year |> Date.new!(12, 31) |> week_of_year()
  end

  @spec weekly_urls(String.t(), Date.t(), pos_integer()) :: [String.t()]
  def weekly_urls(symbol, %Date{} = date, weeks) do
    code = instrument_code(symbol)

    for {year, week} <- recent_year_weeks(date, weeks) do
      "#{@base_url}/m1/#{code}/#{year}/#{week}.csv.gz"
    end
  end

  @spec weeks_needed(String.t(), pos_integer()) :: pos_integer()
  def weeks_needed(timeframe, count) do
    (count * timeframe_minutes(timeframe) / @minutes_per_week)
    |> ceil()
    |> max(1)
    |> min(@max_weeks)
  end

  defp timeframe_minutes("1m"), do: 1
  defp timeframe_minutes("5m"), do: 5
  defp timeframe_minutes("15m"), do: 15
  defp timeframe_minutes("30m"), do: 30
  defp timeframe_minutes("1h"), do: 60
  defp timeframe_minutes("4h"), do: 240
  defp timeframe_minutes("1d"), do: 1440
  defp timeframe_minutes("1w"), do: 10_080
  defp timeframe_minutes(_timeframe), do: 1

  defp cached_download(url) do
    path = cache_path(url)

    cond do
      fresh_cache?(path, url) -> path
      known_missing?(url) -> nil
      download(url, path) == :ok -> path
      File.exists?(path) -> path
      true -> nil
    end
  end

  defp known_missing?(url) do
    case :persistent_term.get({__MODULE__, :missing, url}, nil) do
      nil -> false
      marked_at -> System.os_time(:second) - marked_at < @miss_ttl_seconds
    end
  end

  defp mark_missing(url) do
    :persistent_term.put({__MODULE__, :missing, url}, System.os_time(:second))
  end

  defp cache_path(url) do
    dir = Path.join(System.tmp_dir!(), "fix_alchemy_candledata")
    File.mkdir_p!(dir)
    Path.join(dir, url |> String.replace(@base_url <> "/", "") |> String.replace("/", "_"))
  end

  defp fresh_cache?(path, url) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        immutable_week?(url) or System.os_time(:second) - mtime < @current_week_ttl_seconds

      {:error, _reason} ->
        false
    end
  end

  defp immutable_week?(url) do
    today = Date.utc_today()
    not String.ends_with?(url, "/#{today.year}/#{week_of_year(today)}.csv.gz")
  end

  defp download(url, path) do
    ensure_http_started()

    request = {String.to_charlist(url), []}
    http_opts = [ssl: ssl_options(), timeout: 30_000]

    case :httpc.request(:get, request, http_opts, body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} ->
        File.write!(path, body)
        :ok

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        Logger.warning("CandleData fetch #{url} returned HTTP #{status}")
        if status == 404, do: mark_missing(url)
        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.warning("CandleData fetch #{url} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp ensure_http_started do
    :inets.start()
    :ssl.start()
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  defp query_candles(files, timeframe, count, before) do
    {:ok, db} = Duckdbex.open(":memory:")
    {:ok, conn} = Duckdbex.connection(db)

    Duckdbex.query(conn, "INSTALL core_functions")
    Duckdbex.query(conn, "LOAD core_functions")

    file_list = Enum.map_join(files, " UNION ALL ", &"SELECT * FROM read_csv_auto('#{&1}')")

    result =
      case Duckdbex.query(
             conn,
             candles_sql(file_list, timeframe, before),
             query_params(count, before)
           ) do
        {:ok, ref} ->
          rows = Duckdbex.fetch_all(ref)
          Duckdbex.release(ref)

          candles =
            rows
            |> Enum.map(fn [time, open, high, low, close] ->
              %{time: time, open: open, high: high, low: low, close: close}
            end)
            |> Enum.sort_by(& &1.time)

          {:ok, candles}

        {:error, reason} ->
          Logger.error("CandleData aggregation failed: #{inspect(reason)}")
          {:error, reason}
      end

    Duckdbex.release(conn)
    Duckdbex.release(db)
    result
  end

  defp query_params(count, nil), do: [count]
  defp query_params(count, %DateTime{} = before), do: [DateTime.to_unix(before), count]

  defp cutoff_clause(nil), do: ""
  defp cutoff_clause(%DateTime{}), do: "WHERE time < ?"

  defp candles_sql(file_list, "1m", before) do
    """
    SELECT time, open, high, low, close
    FROM (
      SELECT
        epoch(strptime(DateTime, '%m/%d/%Y %H:%M:%S.%f'))::BIGINT AS time,
        BidOpen AS open, BidHigh AS high, BidLow AS low, BidClose AS close
      FROM (#{file_list})
    )
    #{cutoff_clause(before)}
    ORDER BY time DESC
    LIMIT ?
    """
  end

  defp candles_sql(file_list, timeframe, before) do
    """
    WITH m1 AS (
      SELECT
        strptime(DateTime, '%m/%d/%Y %H:%M:%S.%f') AS dt,
        BidOpen AS open, BidHigh AS high, BidLow AS low, BidClose AS close
      FROM (#{file_list})
    ),
    agg AS (
      SELECT
        TIME_BUCKET(INTERVAL '#{timeframe_minutes(timeframe)} minutes', dt, TIMESTAMP '2000-01-01') AS bucket,
        FIRST(open ORDER BY dt) AS open,
        MAX(high) AS high,
        MIN(low) AS low,
        LAST(close ORDER BY dt) AS close
      FROM m1
      GROUP BY bucket
    )
    SELECT time, open, high, low, close
    FROM (SELECT epoch(bucket)::BIGINT AS time, open, high, low, close FROM agg)
    #{cutoff_clause(before)}
    ORDER BY time DESC
    LIMIT ?
    """
  end
end

defmodule FxcmAlchemy.HistoricalCandles.Backoff do
  @moduledoc """
  Runs a weekly-file download again after the archive refuses it temporarily.

  `retry/2` calls a download that returns `{:ok, term}` or `{:error, reason}`,
  where `reason` is `{:http_status, status, headers}` or an `:httpc` transport
  reason. A `429`, a `5xx` or a dropped connection is waited on and downloaded
  again; a `404`, a `403` and anything else is returned on the first attempt.

  The wait doubles with each attempt up to `:max_ms` and is jittered. When the
  archive sends `Retry-After`, that is the wait instead — unless it is longer
  than `:max_ms`, which ends the attempts rather than holding a chart request
  open for it.

  ## Options

    * `:attempts` - how many times the download may run (default 3)
    * `:base_ms` - ceiling for the first wait (default 500)
    * `:max_ms` - ceiling for any single wait (default 4000)
    * `:sleep` - takes the wait in milliseconds (default `Process.sleep/1`)

  ## Examples

      Backoff.retry(fn -> get(url, path) end, attempts: 5)

  """

  require Logger

  @default_attempts 3
  @default_base_ms 500
  @default_max_ms 4_000

  @retryable_statuses [408, 425, 429, 500, 502, 503, 504]
  @retryable_reasons [:timeout, :etimedout, :closed, :socket_closed_remotely, :econnreset]

  @type answer :: {:ok, term()} | {:error, term()}

  @doc """
  Run `download`, retrying it while the archive's answer is a temporary refusal.
  """
  @spec retry((-> answer()), keyword()) :: answer()
  def retry(download, opts \\ []) when is_function(download, 0) do
    attempt(download, 1, opts)
  end

  @doc """
  Whether the same request may succeed later.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?({:http_status, status, _headers}), do: status in @retryable_statuses
  def retryable?({:failed_connect, _details}), do: true
  def retryable?({reason, _details}) when reason in @retryable_reasons, do: true
  def retryable?(reason) when reason in @retryable_reasons, do: true
  def retryable?(_reason), do: false

  @doc """
  How long to wait before the attempt after `attempt`, in milliseconds.

  Returns `:too_long` when the archive asks for a longer wait than `:max_ms`.
  """
  @spec wait_ms(term(), pos_integer(), keyword()) :: non_neg_integer() | :too_long
  def wait_ms(reason, attempt, opts \\ []) do
    requested_ms(retry_after_ms(reason), attempt, opts)
  end

  defp requested_ms(nil, attempt, opts), do: delay_ms(attempt, opts)

  defp requested_ms(requested, _attempt, opts) do
    if requested > max_ms(opts), do: :too_long, else: requested
  end

  @doc """
  The wait for `attempt` when the archive names none, in milliseconds.
  """
  @spec delay_ms(pos_integer(), keyword()) :: non_neg_integer()
  def delay_ms(attempt, opts \\ []) do
    ceiling = min(base_ms(opts) * 2 ** (attempt - 1), max_ms(opts))
    floor = div(ceiling, 2)

    floor + :rand.uniform(ceiling - floor + 1) - 1
  end

  defp attempt(download, attempt, opts) do
    answer(download.(), download, attempt, opts)
  end

  defp answer({:error, reason} = refusal, download, attempt, opts) do
    case {retryable?(reason) and attempt < attempts(opts), wait_ms(reason, attempt, opts)} do
      {true, wait} when is_integer(wait) ->
        Logger.warning(
          "CandleData refused the download (#{inspect(reason)}); waiting #{wait}ms before attempt #{attempt + 1}"
        )

        sleep(opts).(wait)
        attempt(download, attempt + 1, opts)

      _final ->
        refusal
    end
  end

  defp answer(result, _download, _attempt, _opts), do: result

  defp retry_after_ms({:http_status, _status, headers}) when is_list(headers) do
    headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(to_string(name)) == "retry-after", do: to_string(value)
    end)
    |> parse_retry_after()
  end

  defp retry_after_ms(_reason), do: nil

  defp parse_retry_after(nil), do: nil

  defp parse_retry_after(value) do
    case Integer.parse(value) do
      {seconds, ""} -> seconds * 1000
      _date -> parse_retry_date(value)
    end
  end

  defp parse_retry_date(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      :bad_date ->
        nil

      erl_datetime ->
        erl_datetime
        |> NaiveDateTime.from_erl!()
        |> NaiveDateTime.diff(NaiveDateTime.utc_now(), :millisecond)
        |> max(0)
    end
  end

  defp attempts(opts), do: Keyword.get(opts, :attempts, @default_attempts)
  defp base_ms(opts), do: Keyword.get(opts, :base_ms, @default_base_ms)
  defp max_ms(opts), do: Keyword.get(opts, :max_ms, @default_max_ms)
  defp sleep(opts), do: Keyword.get(opts, :sleep, &Process.sleep/1)
end

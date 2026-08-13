defmodule FxcmAlchemy.HistoricalCandles.BackoffTest do
  @moduledoc """
  A chart asks the archive for several weekly files at once, and the archive
  answers a burst with `429`. The week it refused is there a moment later; the
  week it does not publish never will be, and a `Retry-After` longer than a chart
  will wait for is a refusal to take at its word rather than to sit through.
  """

  use ExUnit.Case, async: true

  alias FxcmAlchemy.HistoricalCandles.Backoff

  @rate_limited {:http_status, 429, []}
  @missing {:http_status, 404, []}

  describe "retry/2" do
    test "a refused week is downloaded on the next attempt" do
      tries = :counters.new(1, [])

      answer =
        Backoff.retry(
          fn ->
            case bump(tries) do
              1 -> {:error, @rate_limited}
              _later -> {:ok, :saved}
            end
          end,
          test_opts()
        )

      assert answer == {:ok, :saved}
      assert :counters.get(tries, 1) == 2
      assert_received {:waited, _ms}
    end

    test "a week the archive does not publish is answered once" do
      tries = :counters.new(1, [])

      answer =
        Backoff.retry(
          fn ->
            bump(tries)
            {:error, @missing}
          end,
          test_opts()
        )

      assert answer == {:error, @missing}
      assert :counters.get(tries, 1) == 1
      refute_received {:waited, _ms}
    end

    test "the attempts are bounded, and the archive's last answer is returned" do
      tries = :counters.new(1, [])

      answer =
        Backoff.retry(
          fn ->
            bump(tries)
            {:error, @rate_limited}
          end,
          test_opts(attempts: 3)
        )

      assert answer == {:error, @rate_limited}
      assert :counters.get(tries, 1) == 3
    end

    test "the wait the archive asks for is the wait it gets" do
      refusal = {:error, {:http_status, 429, [{~c"retry-after", ~c"2"}]}}

      Backoff.retry(fn -> refusal end, test_opts(attempts: 2, max_ms: 5000))

      assert_received {:waited, 2000}
    end

    test "a wait longer than a chart will sit through ends the attempts" do
      tries = :counters.new(1, [])
      refusal = {:error, {:http_status, 429, [{"Retry-After", "600"}]}}

      answer =
        Backoff.retry(
          fn ->
            bump(tries)
            refusal
          end,
          test_opts()
        )

      assert answer == refusal
      assert :counters.get(tries, 1) == 1
      refute_received {:waited, _ms}
    end

    test "a connection that never opened is tried again" do
      tries = :counters.new(1, [])

      answer =
        Backoff.retry(
          fn ->
            case bump(tries) do
              1 -> {:error, {:failed_connect, [{:to_address, {~c"candledata", 443}}]}}
              _later -> {:ok, :saved}
            end
          end,
          test_opts()
        )

      assert answer == {:ok, :saved}
      assert :counters.get(tries, 1) == 2
    end
  end

  describe "retryable?/1" do
    test "the archive asking for less traffic, or failing on its side" do
      assert Backoff.retryable?(@rate_limited)
      assert Backoff.retryable?({:http_status, 503, []})
      assert Backoff.retryable?({:http_status, 504, []})
    end

    test "a request the network dropped" do
      assert Backoff.retryable?(:timeout)
      assert Backoff.retryable?(:socket_closed_remotely)
      assert Backoff.retryable?({:failed_connect, [{:to_address, {~c"host", 443}}]})
    end

    test "an answer the archive will repeat" do
      refute Backoff.retryable?(@missing)
      refute Backoff.retryable?({:http_status, 403, []})
      refute Backoff.retryable?(:enoent)
    end
  end

  describe "wait_ms/3" do
    test "without a Retry-After the wait doubles, up to the ceiling" do
      opts = [base_ms: 1000, max_ms: 8000]

      assert Backoff.wait_ms(@rate_limited, 1, opts) in 500..1000
      assert Backoff.wait_ms(@rate_limited, 2, opts) in 1000..2000
      assert Backoff.wait_ms(@rate_limited, 9, opts) in 4000..8000
    end

    test "a Retry-After date is honoured as well as a Retry-After delay" do
      later =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(3, :second)
        |> NaiveDateTime.to_erl()
        |> :calendar.universal_time_to_local_time()
        |> :httpd_util.rfc1123_date()

      wait = Backoff.wait_ms({:http_status, 429, [{~c"retry-after", later}]}, 1, max_ms: 8000)

      assert wait in 1000..4000
    end

    test "a Retry-After beyond the ceiling is not worth waiting for" do
      assert Backoff.wait_ms({:http_status, 429, [{~c"retry-after", ~c"600"}]}, 1, max_ms: 8000) ==
               :too_long
    end
  end

  defp test_opts(opts \\ []) do
    owner = self()

    Keyword.merge(
      [
        base_ms: 4,
        max_ms: 16,
        sleep: fn ms -> send(owner, {:waited, ms}) end
      ],
      opts
    )
  end

  defp bump(counter) do
    :counters.add(counter, 1, 1)
    :counters.get(counter, 1)
  end
end

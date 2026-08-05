defmodule FxcmAlchemy.HistoricalCandlesTest do
  use ExUnit.Case, async: true

  alias FxcmAlchemy.HistoricalCandles
  alias FxcmAlchemy.HistoricalCandles.FxcmCandleData

  describe "resolve/1" do
    test "defaults to the FXCM CandleData fetcher" do
      assert HistoricalCandles.resolve(%{}) == [FxcmCandleData]

      assert HistoricalCandles.resolve(%{"historical_source" => "fxcm_candledata"}) ==
               [FxcmCandleData]
    end

    test "fxcm_fxlite opts into the native fxlite platform fetcher" do
      assert HistoricalCandles.resolve(%{"historical_source" => "fxcm_fxlite"}) ==
               [FxcmAlchemy.HistoricalCandles.FxcmFxlite]
    end

    test "none disables historical candles" do
      assert HistoricalCandles.resolve(%{"historical_source" => "none"}) == []
    end

    test "custom resolves a user module implementing the behaviour" do
      config = %{
        "historical_source" => "custom",
        "historical_module" => "FxcmAlchemy.HistoricalCandles.FxcmCandleData"
      }

      assert HistoricalCandles.resolve(config) == [FxcmCandleData]
    end

    test "custom with a missing or invalid module resolves to nothing" do
      assert HistoricalCandles.resolve(%{
               "historical_source" => "custom",
               "historical_module" => "Does.Not.Exist"
             }) == []

      assert HistoricalCandles.resolve(%{"historical_source" => "custom"}) == []
    end
  end

  describe "FxcmFxlite.to_chart_candle/1" do
    test "maps bid OHLC and unix time" do
      candle = %FxliteAlchemy.PriceHistory.Candle{
        timestamp: ~U[2026-07-20 08:00:00Z],
        bid_open: 1.1,
        bid_close: 1.2,
        bid_high: 1.3,
        bid_low: 1.0,
        ask_open: 1.15,
        ask_close: 1.25,
        ask_high: 1.35,
        ask_low: 1.05,
        volume: 7
      }

      assert FxcmAlchemy.HistoricalCandles.FxcmFxlite.to_chart_candle(candle) == %{
               time: 1_784_534_400,
               open: 1.1,
               high: 1.3,
               low: 1.0,
               close: 1.2
             }
    end
  end

  describe "FxcmFxlite.window_from/3" do
    test "covers the requested count with weekend margin" do
      now = ~U[2026-07-22 06:00:00Z]
      from = FxcmAlchemy.HistoricalCandles.FxcmFxlite.window_from("1m", 500, now)

      assert DateTime.diff(now, from, :second) >= 500 * 60 * 2
    end
  end

  describe "FxcmFxlite.session_opts/1" do
    test "reads fxlite settings with platform defaults" do
      opts =
        FxcmAlchemy.HistoricalCandles.FxcmFxlite.session_opts(%{
          "fxlite_username" => "platform_user",
          "fxlite_password" => "platform_pass"
        })

      assert opts[:url] == "https://www.fxcorporate.com"
      assert opts[:connection_name] == "Demo"
      assert opts[:username] == "platform_user"
      assert opts[:password] == "platform_pass"
    end

    test "falls back to the FIX credentials" do
      opts =
        FxcmAlchemy.HistoricalCandles.FxcmFxlite.session_opts(%{
          "username" => "fix_user",
          "password" => "fix_pass",
          "fxlite_url" => "https://fxcorpx.fxcorporate.com",
          "fxlite_connection" => "QAReal"
        })

      assert opts[:url] == "https://fxcorpx.fxcorporate.com"
      assert opts[:connection_name] == "QAReal"
      assert opts[:username] == "fix_user"
      assert opts[:password] == "fix_pass"
    end
  end

  describe "FxcmCandleData.instrument_code/1" do
    test "strips separators from platform symbols" do
      assert FxcmCandleData.instrument_code("EUR/USD") == "EURUSD"
      assert FxcmCandleData.instrument_code("XAG/USD") == "XAGUSD"
      assert FxcmCandleData.instrument_code("USDJPY") == "USDJPY"
    end
  end

  describe "FxcmCandleData.week_of_year/1" do
    test "matches the FXCM CandleData week convention" do
      assert FxcmCandleData.week_of_year(~D[2020-01-01]) == 1
      assert FxcmCandleData.week_of_year(~D[2020-01-07]) == 1
      assert FxcmCandleData.week_of_year(~D[2020-01-08]) == 2
      assert FxcmCandleData.week_of_year(~D[2020-12-31]) == 53
    end
  end

  describe "FxcmCandleData.recent_year_weeks/2" do
    test "returns the most recent weeks newest first" do
      assert FxcmCandleData.recent_year_weeks(~D[2020-03-14], 2) == [{2020, 11}, {2020, 10}]
    end

    test "crosses the year boundary" do
      assert FxcmCandleData.recent_year_weeks(~D[2021-01-03], 3) ==
               [{2021, 1}, {2020, 53}, {2020, 52}]
    end
  end

  describe "FxcmCandleData.weekly_urls/3" do
    test "builds m1 weekly urls for the fetch window" do
      assert FxcmCandleData.weekly_urls("EUR/USD", ~D[2020-03-14], 2) == [
               "https://candledata.fxcorporate.com/m1/EURUSD/2020/11.csv.gz",
               "https://candledata.fxcorporate.com/m1/EURUSD/2020/10.csv.gz"
             ]
    end
  end

  describe "FxcmCandleData.weeks_needed/2" do
    test "covers the requested count at the requested timeframe" do
      assert FxcmCandleData.weeks_needed("1m", 500) == 1
      assert FxcmCandleData.weeks_needed("1h", 500) == 5
    end

    test "is capped to keep downloads bounded" do
      assert FxcmCandleData.weeks_needed("4h", 500) == 8
    end
  end

  describe "FxcmCandleData.probe_window/2" do
    test "extends past the needed weeks to skip the archive publication lag" do
      assert FxcmCandleData.probe_window("1m", 500) == 13
    end

    test "is capped to keep the probe bounded" do
      assert FxcmCandleData.probe_window("4h", 500) == 16
    end
  end
end

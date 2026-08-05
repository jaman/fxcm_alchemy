defmodule FxcmAlchemy.TradingBackend do
  @moduledoc """
  FXCM's platform trading backend (id `:fxcm`).

  Extends the baseline `FixAlchemy.Backend` with FXCM specifics: the FXCM
  handshake/market-data/portfolio handlers, deferred readiness (business
  messages wait for FXCM's post-logon flow), FXCM close semantics via
  `FxcmAlchemy`, the collateral/fxlite/historical config fields, and a P&L
  position tracker started per trading connection.

  Auto-discovered by the platform when `fxcm_alchemy` is a dependency.
  """

  use FixAlchemy.Backend

  @impl FixAlchemy.Backend
  def backend_config do
    %{
      FixAlchemy.Backend.default_config()
      | id: :fxcm,
        name: "FXCM (FIX)",
        fields: FixAlchemy.Backend.default_fields() ++ fxcm_fields(),
        groups:
          FixAlchemy.Backend.default_groups() ++
            [
              %{
                id: :historical,
                label: "Historical Data",
                description: "Where chart history is fetched from"
              }
            ]
    }
  end

  @impl FixAlchemy.Backend
  def handlers, do: [FxcmAlchemy.Session, FxcmAlchemy.MarketData, FxcmAlchemy.Portfolio]

  @impl FixAlchemy.Backend
  def defer_ready?, do: true

  @impl FixAlchemy.Backend
  def trading_module, do: FxcmAlchemy

  @impl FixAlchemy.Backend
  def start_extras(connection_id, config) do
    case Registry.lookup(FixAlchemy.Registry, {connection_id, :position_tracker}) do
      [{pid, _}] when is_pid(pid) ->
        {:ok, pid}

      [] ->
        tracker_opts = [
          connection_id: connection_id,
          base_currency: Keyword.get(config, :base_currency, "USD"),
          initial_balance: Keyword.get(config, :initial_balance, 10_000.0)
        ]

        DynamicSupervisor.start_child(
          FixAlchemy.ClientSupervisor,
          {FxcmAlchemy.PositionTracker, tracker_opts}
        )
    end
  end

  @impl FixAlchemy.Backend
  def stop_extras(connection_id) do
    case Registry.lookup(FixAlchemy.Registry, {connection_id, :position_tracker}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(FixAlchemy.ClientSupervisor, pid)
      [] -> :ok
    end
  end

  @impl FixAlchemy.Backend
  def get_historical_candles(connection_id, symbol, opts) do
    config = Keyword.get(opts, :config, %{})
    opts = Keyword.put(opts, :connection_id, connection_id)

    case FxcmAlchemy.HistoricalCandles.resolve(config) do
      [] ->
        {:error, :not_supported}

      modules ->
        Enum.reduce_while(modules, {:error, :not_supported}, fn module, _last_error ->
          case module.fetch_candles(symbol, opts) do
            {:ok, candles} -> {:halt, {:ok, candles}}
            {:error, reason} -> {:cont, {:error, reason}}
          end
        end)
    end
  end

  defp fxcm_fields do
    [
      %{
        name: :historical_source,
        type: :select,
        group: :historical,
        overridable: false,
        label: "Historical Candles",
        required: false,
        options: [
          %{label: "FXCM CandleData (public, delayed)", value: "fxcm_candledata"},
          %{label: "FXCM fxlite platform (current)", value: "fxcm_fxlite"},
          %{label: "FIX session (native)", value: "fix_session"},
          %{label: "Custom module", value: "custom"},
          %{label: "None", value: "none"}
        ],
        description: "Source for chart history; FIX itself carries no historical data"
      },
      %{
        name: :historical_module,
        type: :string,
        group: :historical,
        overridable: false,
        label: "Historical Module",
        required: false,
        description:
          "Module implementing FxcmAlchemy.HistoricalCandles (used when source is Custom)"
      },
      %{
        name: :fxlite_username,
        type: :string,
        group: :historical,
        overridable: false,
        label: "fxlite Username",
        required: false,
        description: "FXCM platform login for fxlite historical data (defaults to Username)"
      },
      %{
        name: :fxlite_password,
        type: :password,
        group: :historical,
        overridable: false,
        label: "fxlite Password",
        required: false,
        description: "FXCM platform password (defaults to Password)"
      },
      %{
        name: :fxlite_url,
        type: :string,
        group: :historical,
        overridable: false,
        label: "fxlite Server URL",
        required: false,
        description: "Hosts.jsp base URL (default https://www.fxcorporate.com)"
      },
      %{
        name: :fxlite_connection,
        type: :string,
        group: :historical,
        overridable: false,
        label: "fxlite Connection",
        required: false,
        description: "fxlite connection name, e.g. Demo or Real (default Demo)"
      }
    ]
  end
end

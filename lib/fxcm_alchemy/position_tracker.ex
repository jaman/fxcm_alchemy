defmodule FxcmAlchemy.PositionTracker do
  @moduledoc """
  Tracks positions and calculates P&L for FIX connections.

  Subscribes to position updates from FIX Client and market data updates,
  calculates unrealized P&L, and broadcasts enriched position and account data.

  Publishing goes through `FixAlchemy.PubSub`, on the server given by the
  `:pubsub_module` start option or, failing that, the engine's own
  `config :fix_alchemy, :pubsub_server`. Updates are published on
  `"position:<connection_id>"` and `"account:<connection_id>"`.

  `:market_data_subscriber` names the module the tracker asks for prices, so a
  tracker is told what to subscribe through rather than reading it globally.

  `:session_name` names the session whose portfolio holds the account, and must
  match the session the connection runs under. A tracker pointed at a session
  that does not exist reads no account, and an account is what carries P&L, so
  the panel goes quiet without anything failing.

  With no server configured the tracker runs and publishes nothing. A host
  without `phoenix_pubsub` consumes the updates by configuring its own
  `FixAlchemy.PubSub` implementation under `config :fix_alchemy, :pubsub`.
  """

  use GenServer
  require Logger

  @compile {:no_warn_undefined, Phoenix.PubSub}

  defstruct [
    :connection_id,
    :session_name,
    :base_currency,
    :pubsub_module,
    :market_data_subscriber,
    positions: %{},
    current_prices: %{},
    realized_pnl: 0.0
  ]

  def start_link(opts) do
    connection_id = Keyword.fetch!(opts, :connection_id)
    name = {:via, Registry, {FixAlchemy.Registry, {connection_id, :position_tracker}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :connection_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @impl true
  def init(opts) do
    connection_id = Keyword.fetch!(opts, :connection_id)
    base_currency = Keyword.get(opts, :base_currency, "USD")

    pubsub_module = Keyword.get(opts, :pubsub_module) || FixAlchemy.PubSub.server()
    subscriber = Keyword.get(opts, :market_data_subscriber)

    subscribe(pubsub_module, "position_raw:#{connection_id}")

    state = %__MODULE__{
      connection_id: connection_id,
      session_name: Keyword.get(opts, :session_name, :trading),
      base_currency: base_currency,
      pubsub_module: pubsub_module,
      market_data_subscriber: subscriber,
      positions: %{},
      current_prices: %{},
      realized_pnl: 0.0
    }

    {:ok, state}
  end

  defp subscribe(server, topic) do
    if phoenix_pubsub_running?(server), do: Phoenix.PubSub.subscribe(server, topic)
    :ok
  end

  defp unsubscribe(server, topic) do
    if phoenix_pubsub_running?(server), do: Phoenix.PubSub.unsubscribe(server, topic)
    :ok
  end

  defp phoenix_pubsub_running?(server) when is_atom(server) and not is_nil(server),
    do: Code.ensure_loaded?(Phoenix.PubSub) and Process.whereis(server) != nil

  defp phoenix_pubsub_running?(_server), do: false

  defp register_subscription(nil, _pid, _topic, _metadata), do: {:ok, :created}

  defp register_subscription(subscriber, pid, topic, metadata),
    do: subscriber.subscribe(pid, topic, metadata)

  defp deregister_subscription(nil, _pid, _topic), do: {:ok, :destroyed}
  defp deregister_subscription(subscriber, pid, topic), do: subscriber.unsubscribe(pid, topic)

  @impl true
  def handle_info({:position_update, positions}, state) do
    positions_map = normalize_positions(positions)

    Logger.debug(
      "Normalized positions: #{inspect(positions_map |> Map.values() |> Enum.map(&Map.take(&1, [:id, :symbol, :quantity, :entry_price])))}"
    )

    old_symbols = state.positions |> Map.values() |> Enum.map(& &1.symbol) |> MapSet.new()
    new_symbols = positions_map |> Map.values() |> Enum.map(& &1.symbol) |> MapSet.new()

    to_subscribe = MapSet.difference(new_symbols, old_symbols) |> MapSet.to_list()
    to_unsubscribe = MapSet.difference(old_symbols, new_symbols) |> MapSet.to_list()

    Enum.each(to_subscribe, &subscribe_symbol(state, &1))

    Enum.each(to_unsubscribe, fn symbol ->
      Logger.debug("PositionTracker unsubscribing from market data for #{symbol}")

      topic = "instruments:#{state.connection_id}:#{symbol}"
      unsubscribe(state.pubsub_module, topic)

      case deregister_subscription(state.market_data_subscriber, self(), topic) do
        {:ok, :destroyed} ->
          Logger.debug("Last subscriber left - unsubscribing from broker for #{symbol}")
          FxcmAlchemy.TradingBackend.unsubscribe_market_data(state.connection_id, [symbol])

        {:ok, :left} ->
          Logger.debug("Other subscribers remain for #{symbol}, keeping broker subscription")

        {:error, reason} ->
          Logger.warning("Failed to unregister subscription for #{symbol}: #{inspect(reason)}")
      end
    end)

    base = account_base(state)
    currency = currency_of(base, state)

    positions_with_pnl =
      calculate_all_pnl(positions_map, state.current_prices, currency)

    new_state = %{state | positions: positions_with_pnl, base_currency: currency}

    broadcast_positions(new_state)
    broadcast_account(base, new_state)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:market_data_update, _connection_id, symbol, data}, state) do
    price_data = %{
      bid: parse_float(Map.get(data, :bid)),
      ask: parse_float(Map.get(data, :ask))
    }

    new_current_prices = Map.put(state.current_prices, symbol, price_data)
    base = account_base(state)
    currency = currency_of(base, state)

    positions_with_pnl =
      calculate_all_pnl(state.positions, new_current_prices, currency)

    new_state = %{
      state
      | positions: positions_with_pnl,
        current_prices: new_current_prices,
        base_currency: currency
    }

    broadcast_positions(new_state)
    broadcast_account(base, new_state)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:retry_subscribe, symbol}, state) do
    Logger.debug("Retrying market data subscription for #{symbol}")

    case FxcmAlchemy.TradingBackend.subscribe_market_data(
           state.connection_id,
           [symbol],
           state.pubsub_module,
           "instruments:#{state.connection_id}:#{symbol}"
         ) do
      :ok ->
        Logger.debug("Successfully subscribed to market data for #{symbol} on retry")

      {:error, reason} ->
        Logger.warning("Retry failed for #{symbol}: #{inspect(reason)}. Will retry again.")
        Process.send_after(self(), {:retry_subscribe, symbol}, 2000)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp normalize_positions(positions) when is_map(positions) do
    positions
    |> Enum.map(fn {id, pos} ->
      {id, normalize_position(pos)}
    end)
    |> Map.new()
  end

  defp subscribe_symbol(state, symbol) do
    Logger.debug("PositionTracker subscribing to market data for #{symbol}")

    topic = "instruments:#{state.connection_id}:#{symbol}"
    subscribe(state.pubsub_module, topic)

    registered =
      register_subscription(
        state.market_data_subscriber,
        self(),
        topic,
        %{source: :position_tracker}
      )

    handle_registration(registered, state, symbol, topic)
  end

  defp handle_registration({:ok, :created}, state, symbol, topic) do
    Logger.debug("First subscriber - requesting market data from broker for #{symbol}")

    requested =
      FxcmAlchemy.TradingBackend.subscribe_market_data(
        state.connection_id,
        [symbol],
        state.pubsub_module,
        topic
      )

    log_market_data_request(requested, symbol)
  end

  defp handle_registration({:ok, :joined}, _state, symbol, _topic) do
    Logger.debug("Joined existing subscription for #{symbol}")
  end

  defp handle_registration({:error, reason}, _state, symbol, _topic) do
    Logger.warning("Failed to register subscription for #{symbol}: #{inspect(reason)}")
  end

  defp log_market_data_request(:ok, symbol) do
    Logger.debug("Successfully requested market data for #{symbol}")
  end

  defp log_market_data_request({:error, reason}, symbol) do
    Logger.warning("Failed to request market data for #{symbol}: #{inspect(reason)}")
    Process.send_after(self(), {:retry_subscribe, symbol}, 2000)
  end

  defp normalize_position(pos) when is_map(pos) do
    data = if Map.has_key?(pos, :data), do: pos.data, else: pos
    entry = reported_float(data, pos, [:avg_price, :settl_price])

    %{
      id: reported(data, pos, [:position_id, :fxcm_pos_id]),
      symbol: reported(data, pos, [:symbol]),
      side: normalize_side(reported(data, pos, [:side])),
      quantity: reported_float(data, pos, [:size]),
      entry_price: entry,
      current_price: entry,
      unrealized_pnl: 0.0,
      order_id: reported(data, pos, [:order_id])
    }
  end

  defp reported(data, pos, keys) do
    Enum.find_value(keys, fn key -> Map.get(data, key) || Map.get(pos, key) end)
  end

  defp reported_float(data, pos, keys), do: parse_float(reported(data, pos, keys)) || 0.0

  defp normalize_side(nil), do: :buy
  defp normalize_side(side) when side in [:buy, "buy", "1"], do: :buy
  defp normalize_side(side) when side in [:sell, "sell", "2"], do: :sell
  defp normalize_side(side) when side in [:long, "long"], do: :buy
  defp normalize_side(side) when side in [:short, "short"], do: :sell
  defp normalize_side(_), do: :buy

  defp calculate_all_pnl(positions, current_prices, base_currency) do
    positions
    |> Enum.map(fn {id, pos} ->
      {pnl, current_price} = calculate_position_pnl(pos, current_prices, base_currency)

      updated_pos =
        pos
        |> Map.put(:unrealized_pnl, pnl)
        |> Map.put(:current_price, current_price)

      {id, updated_pos}
    end)
    |> Map.new()
  end

  defp calculate_position_pnl(position, current_prices, base_currency) do
    price_data = Map.get(current_prices, position.symbol)

    if price_data && position.entry_price && position.quantity do
      current_price =
        case position.side do
          :buy -> price_data.bid
          :sell -> price_data.ask
        end

      {FxcmAlchemy.PnL.position_pnl(position, current_prices, base_currency), current_price}
    else
      {0.0, position.entry_price}
    end
  end

  defp parse_float(nil), do: nil
  defp parse_float(val) when is_float(val), do: val
  defp parse_float(val) when is_integer(val), do: val * 1.0

  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {num, _} -> num
      :error -> nil
    end
  end

  defp parse_float(_), do: nil

  defp broadcast_positions(state) do
    positions_by_symbol =
      state.positions
      |> Map.values()
      |> Enum.map(fn pos -> Map.put(pos, :connection_id, state.connection_id) end)
      |> Enum.group_by(& &1.symbol)

    FixAlchemy.PubSub.broadcast(
      state.pubsub_module,
      "position:#{state.connection_id}",
      {:position_update, positions_by_symbol}
    )
  end

  defp account_base(state) do
    FixAlchemy.Portfolio.get_account_summary(state.connection_id, state.session_name)
  catch
    :exit, _gone ->
      Logger.debug("No portfolio to read an account from for #{state.connection_id}")
      nil
  end

  defp currency_of(%{currency: currency}, _state) when is_binary(currency), do: currency
  defp currency_of(_base, state), do: state.base_currency

  defp broadcast_account(nil, _state), do: :ok

  defp broadcast_account(base, state) do
    FixAlchemy.PubSub.broadcast(
      state.pubsub_module,
      "account:#{state.connection_id}",
      {:account_update, enrich_account_summary(base, state)}
    )
  end

  defp enrich_account_summary(base, state) do
    total_unrealized_pnl =
      state.positions
      |> Map.values()
      |> Enum.map(& &1.unrealized_pnl)
      |> Enum.sum()

    balance = base.balance

    %{
      account_id: base.account_id,
      balance: balance,
      equity: balance + total_unrealized_pnl,
      unrealized_pnl: total_unrealized_pnl,
      realized_pnl: state.realized_pnl,
      total_pnl: state.realized_pnl + total_unrealized_pnl,
      margin_used: base.margin_used,
      margin_available: base.margin_available,
      currency: base.currency,
      base_currency: state.base_currency
    }
  end
end

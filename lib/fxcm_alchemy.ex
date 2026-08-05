defmodule FxcmAlchemy do
  @moduledoc """
  FXCM trading adapter built on the `FixAlchemy` engine.

  FXCM is one backend among many: the generic engine frames and routes the FIX
  stream, and `FixAlchemy.Trading` supplies the standard order-entry and
  account-read surface, which this module re-exports. The only FXCM-specific
  behaviour is position closing: FXCM legs positions by `FXCMPosID` (`9041`) and
  a netting position closes by sizing out its own quantity.
  """

  require Logger

  alias FixAlchemy.Trading

  @max_order_qty 100_000_000

  defdelegate order(conn, symbol, size, side, opts \\ []), to: Trading
  defdelegate limit_order(conn, symbol, size, side, price, opts \\ []), to: Trading
  defdelegate stop_order(conn, symbol, size, side, stop_price, opts \\ []), to: Trading
  defdelegate order_list(conn, contingency, orders), to: Trading
  defdelegate bracket_order(conn, symbol, quantity, side, opts), to: Trading
  defdelegate cancel_order(conn, order_id), to: Trading
  defdelegate modify_order(conn, order_id, opts \\ []), to: Trading
  defdelegate close_position(conn, symbol, size, opts \\ []), to: Trading
  defdelegate request_positions(conn, opts \\ []), to: Trading
  defdelegate request_orders(conn), to: Trading
  defdelegate request_collateral(conn), to: Trading
  defdelegate request_instruments(conn), to: Trading
  defdelegate subscribe_market_data(conn, instruments), to: Trading
  defdelegate unsubscribe_market_data(conn, instruments), to: Trading
  defdelegate request_historical_candles(conn, symbol, opts \\ []), to: Trading
  defdelegate get_account(conn), to: Trading
  defdelegate get_positions(conn), to: Trading
  defdelegate get_positions_by_symbol(conn, symbol), to: Trading
  defdelegate get_position(conn, position_id), to: Trading
  defdelegate get_orders(conn), to: Trading
  defdelegate get_order(conn, order_id), to: Trading
  defdelegate get_collateral(conn), to: Trading
  defdelegate get_account_summary(conn), to: Trading
  defdelegate list_instruments(conn), to: Trading
  defdelegate get_instrument(conn, instrument), to: Trading
  defdelegate get_capabilities(conn), to: Trading

  @doc """
  Attach stop loss and/or take profit to an open position.

  A position given with `:pos_id` is tagged with FXCMPosID (`9041`) so the
  protective orders bind to that leg.
  """
  @spec attach_protection(GenServer.server(), map(), keyword()) ::
          :ok | {:error, :no_protection_given}
  def attach_protection(conn, position, opts) do
    Trading.attach_protection(conn, tag_position(position), opts)
  end

  defp tag_position(%{pos_id: pos_id} = position) when not is_nil(pos_id),
    do: Map.put(position, :extra_fields, [{9041, pos_id}])

  defp tag_position(position), do: position

  @doc """
  Close a position by ID.

  FXCM legs by `9041`; a netting position closes by offsetting its own quantity.
  """
  @spec close_position_by_id(GenServer.server(), binary(), integer() | nil, keyword()) ::
          :ok | {:error, term()}
  def close_position_by_id(conn, position_id, size, opts \\ []) do
    with {:ok, position} <- fetch_position(conn, position_id),
         {:ok, symbol} <- fetch_position_symbol(position, position_id) do
      close_by_provenance(conn, position, position_id, symbol, size, opts)
    end
  end

  @doc "Close every position for a symbol, each on its own terms."
  @spec close_all_for_symbol(GenServer.server(), binary(), keyword()) :: :ok
  def close_all_for_symbol(conn, symbol, opts \\ []) do
    conn
    |> get_positions_by_symbol(symbol)
    |> Enum.each(fn position ->
      close_position_by_id(conn, position.position_id, size_to_int(position.size), opts)
    end)

    :ok
  end

  defp close_by_provenance(conn, %{via: :report} = position, _position_id, symbol, _size, _opts) do
    size_out(conn, symbol, signed_size(position))
  end

  defp close_by_provenance(conn, position, position_id, symbol, size, opts) do
    with {:ok, signed_qty} <- resolve_signed_qty(size, position, position_id),
         {close_side, close_size} = close_order_for(signed_qty, position),
         :ok <- guard_order_qty(position_id, symbol, close_size) do
      Logger.info("Closing position #{position_id}: #{symbol} #{close_side} #{close_size}")

      opts =
        opts
        |> Keyword.put(:position_effect, "C")
        |> Keyword.put(:extra_fields, [{9041, position_id}])

      order(conn, symbol, close_size, close_side, opts)
    end
  end

  defp size_out(_conn, symbol, 0) do
    Logger.info("Nothing to size out for #{symbol}")
    :ok
  end

  defp size_out(conn, symbol, signed) do
    close_side = if signed > 0, do: :sell, else: :buy
    qty = abs(signed)

    case guard_order_qty(symbol, symbol, qty) do
      :ok ->
        Logger.info("Sizing out #{symbol}: #{close_side} #{qty}")
        order(conn, symbol, qty, close_side, order_type: "1")

      error ->
        error
    end
  end

  defp guard_order_qty(position_id, symbol, qty) when qty > @max_order_qty do
    Logger.error(
      "Refusing to close #{position_id} (#{symbol}): quantity #{qty} exceeds sane max " <>
        "#{@max_order_qty} — likely a notional/units mix-up, not sending."
    )

    {:error, :quantity_too_large}
  end

  defp guard_order_qty(_position_id, _symbol, _qty), do: :ok

  defp fetch_position(conn, position_id) do
    case get_position(conn, position_id) do
      nil ->
        Logger.error("Position #{position_id} not found, cannot close")
        {:error, :position_not_found}

      position ->
        {:ok, position}
    end
  end

  defp fetch_position_symbol(position, position_id) do
    case position[:symbol] do
      nil ->
        Logger.error("Position #{position_id} has no symbol: #{inspect(position)}")
        {:error, :no_symbol}

      symbol ->
        {:ok, symbol}
    end
  end

  defp resolve_signed_qty(size, _position, _position_id) when is_integer(size), do: {:ok, size}

  defp resolve_signed_qty(nil, position, position_id) do
    case position[:size] do
      nil ->
        Logger.error("Could not determine position size for #{position_id}: #{inspect(position)}")
        {:error, :no_size}

      size when is_binary(size) ->
        {:ok, String.to_integer(size)}

      size when is_integer(size) ->
        {:ok, size}
    end
  end

  defp close_order_for(signed_qty, position) do
    long? =
      cond do
        signed_qty < 0 -> false
        position[:side] in [:sell, :short] -> false
        true -> true
      end

    close_side = if long?, do: :sell, else: :buy
    {close_side, abs(signed_qty)}
  end

  defp signed_size(position) do
    magnitude = position |> Map.get(:size, "0") |> size_to_int() |> abs()

    case Map.get(position, :side) do
      side when side in [:sell, :short] -> -magnitude
      _long -> magnitude
    end
  end

  defp size_to_int(size) when is_integer(size), do: size

  defp size_to_int(size) when is_binary(size) do
    case Integer.parse(size) do
      {int, _rest} -> int
      :error -> 0
    end
  end

  defp size_to_int(_size), do: 0
end

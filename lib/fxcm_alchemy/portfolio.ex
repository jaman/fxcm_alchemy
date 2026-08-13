defmodule FxcmAlchemy.Portfolio do
  @moduledoc """
  FXCM's per-session portfolio subscriber.

  Extends the plain-FIX `FixAlchemy.Portfolio` with FXCM's proprietary trading
  identity: positions keyed by FXCMPosID (`9041`), fills recognized only when
  they carry that id, position reports that close on FXCM's close indicators,
  and an account summary built from the CollateralReport (`BA`) / ack (`BG`).

  FXCM sends one CollateralReport per account of the login. Each is filed under
  the account it reports on, so the summary is that of the account in force and
  the login's accounts are the ones `FixAlchemy.Portfolio.list_accounts/2`
  offers.

  Order tracking, the get/broadcast machinery, and the GenServer lifecycle come
  from the base; only the FXCM-specific message flow is overridden.
  """

  use FixAlchemy.Portfolio

  require Logger

  alias FixAlchemy.Parser
  alias FixAlchemy.Portfolio, as: Base

  @impl FixAlchemy.Portfolio
  def subscribed_types, do: super() ++ ["BA", "BG"]

  @impl FixAlchemy.Portfolio
  def handle_message("BA", raw_msg, _meta, state) do
    msg = Base.decode(raw_msg, state)
    Base.put_collateral(state, Map.get(msg, :account), Map.delete(msg, :raw))
  end

  def handle_message("BG", raw_msg, _meta, state) do
    msg = Base.decode(raw_msg, state)
    Base.put_collateral(state, nil, Map.delete(msg, :raw))
  end

  def handle_message(type, raw_msg, meta, state), do: super(type, raw_msg, meta, state)

  @impl FixAlchemy.Portfolio
  def apply_execution_report(positions, msg, order, order_id, state) do
    ord_status = Map.get(msg, :ord_status)
    exec_type = Map.get(msg, :exec_type)
    symbol = Map.get(msg, :symbol)
    status_report? = exec_type == "I" || Map.get(msg, :mass_status_req_id) != nil

    cond do
      vanished?(msg, positions) ->
        forget_vanished(positions, msg, state)

      !(symbol && ord_status in ["1", "2"] && !status_report?) ->
        positions

      Map.get(msg, :fxcm_pos_id) == nil ->
        positions

      true ->
        apply_fill(positions, msg, order, order_id, state)
    end
  end

  defp vanished?(msg, positions) do
    pos_id = refused_position(msg)

    Map.get(msg, :ord_status) == "8" and pos_id != nil and
      Map.has_key?(positions, pos_id) and refers_to_missing_trade?(msg)
  end

  defp refused_position(msg), do: Map.get(msg, :fxcm_pos_id) || raw_field(msg, "9041")

  defp refers_to_missing_trade?(msg) do
    [Map.get(msg, :text), raw_field(msg, "58"), raw_field(msg, "9029")]
    |> Enum.filter(&is_binary/1)
    |> Enum.any?(&(&1 |> String.downcase() |> String.contains?("cannot find a trade")))
  end

  defp raw_field(msg, tag) do
    case Map.get(msg, :raw) do
      raw when is_binary(raw) -> raw |> Parser.split_fields() |> Map.new() |> Map.get(tag)
      _absent -> nil
    end
  end

  defp forget_vanished(positions, msg, state) do
    pos_id = refused_position(msg)

    Logger.info(
      "Position #{pos_id} refused as unknown to the broker, dropping it: " <>
        inspect(Map.get(msg, :text) || raw_field(msg, "58")),
      source: state.process_name
    )

    Map.delete(positions, pos_id)
  end

  @impl FixAlchemy.Portfolio
  def apply_position_report(positions, raw_msg, state) do
    field_map = raw_msg |> Parser.split_fields() |> Map.new()

    symbol = Map.get(field_map, "55")
    pos_id = Map.get(field_map, "9041") || Map.get(field_map, "721")
    long_qty = Map.get(field_map, "704")
    short_qty = Map.get(field_map, "705")

    msg = Base.decode(raw_msg, state)
    close_cl_ord_id = Map.get(msg, :fxcm_close_cl_ord_id)
    close_pnl = Map.get(msg, :fxcm_pos_close_pnl)
    pos_req_type = Map.get(msg, :pos_req_type)

    net = Base.net_quantity(long_qty, short_qty)
    size = Integer.to_string(abs(net))
    side = if net >= 0, do: :buy, else: :sell

    Logger.info(
      "PositionReport: symbol=#{symbol}, pos_id=#{pos_id}, #{side} #{size} (net #{net}), " <>
        "req_type=#{inspect(pos_req_type)}",
      source: state.process_name
    )

    reported = %{
      pos_id: pos_id,
      closed?: !!(close_cl_ord_id || close_pnl),
      trade_report?: pos_req_type == "1",
      net: net
    }

    apply_reported_position(reported, positions, state, fn ->
      %{
        symbol: symbol,
        size: size,
        side: side,
        via: :report,
        avg_price: open_price(field_map, msg),
        unrealized_pl: Map.get(field_map, "900") || Map.get(msg, :settl_curr_amt),
        position_id: pos_id,
        order_id: Map.get(msg, :order_id),
        last_update: DateTime.utc_now(),
        data: Map.delete(msg, :raw)
      }
    end)
  end

  defp apply_reported_position(%{pos_id: nil}, positions, state, _build) do
    Logger.warning("PositionReport missing pos_id, not storing", source: state.process_name)
    positions
  end

  defp apply_reported_position(%{closed?: true} = reported, positions, state, _build) do
    Logger.info(
      "Position closed via PositionReport (close indicators present): #{reported.pos_id}",
      source: state.process_name
    )

    Map.delete(positions, reported.pos_id)
  end

  defp apply_reported_position(%{trade_report?: true} = reported, positions, state, _build) do
    Logger.debug("Skipping trade report (not a position snapshot): #{reported.pos_id}",
      source: state.process_name
    )

    positions
  end

  defp apply_reported_position(%{net: 0} = reported, positions, state, _build) do
    Logger.info("Position closed via PositionReport (qty=0): #{reported.pos_id}",
      source: state.process_name
    )

    Map.delete(positions, reported.pos_id)
  end

  defp apply_reported_position(reported, positions, _state, build) do
    Map.put(positions, reported.pos_id, build.())
  end

  @impl FixAlchemy.Portfolio
  def build_account_summary(state) do
    case Base.collateral(state) do
      collateral when is_map(collateral) -> collateral_summary(collateral, state)
      _none -> Base.standard_account_summary(state)
    end
  end

  defp collateral_summary(collateral, state) do
    balance = Base.parse_float(Map.get(collateral, :end_cash))
    equity = nonzero_or(Base.parse_float(Map.get(collateral, :total_net_value)), balance)
    margin_used = Base.parse_float(Map.get(collateral, :fxcm_used_margin))

    usable =
      nonzero_or(Base.parse_float(Map.get(collateral, :margin_excess)), equity - margin_used)

    %{
      account_id: Map.get(collateral, :account) || Base.active_account(state) || "N/A",
      balance: balance,
      equity: equity,
      margin_used: margin_used,
      margin_available: usable,
      currency: presence(Map.get(collateral, :currency)),
      unrealized_pnl: 0.0
    }
  end

  defp apply_fill(positions, msg, order, order_id, state) do
    symbol = Map.get(msg, :symbol)
    side = Map.get(msg, :side)
    cum_qty = Map.get(msg, :cum_qty) || Map.get(msg, :last_qty) || "0"
    avg_px = Map.get(msg, :avg_px) || Map.get(msg, :last_px)

    position_id = Map.get(msg, :fxcm_pos_id)

    remaining_qty =
      remaining_quantity(Map.get(positions, position_id), Map.get(msg, :fxcm_ord_type), cum_qty)

    Logger.info(
      "ExecutionReport: symbol=#{symbol}, status=#{Map.get(msg, :ord_status)}, " <>
        "type=#{Map.get(msg, :exec_type)}, pos_id=#{position_id}, qty=#{cum_qty}, " <>
        "remaining=#{remaining_qty}, side=#{side}",
      source: state.process_name
    )

    if remaining_qty == "0" do
      Logger.info("Position closed via ExecutionReport: #{position_id}",
        source: state.process_name
      )

      Map.delete(positions, position_id)
    else
      position = %{
        symbol: symbol,
        size: remaining_qty,
        side: if(side == "1", do: :buy, else: :sell),
        avg_price: avg_px,
        via: :fill,
        position_id: position_id,
        order_id: order_id,
        last_update: DateTime.utc_now(),
        data: order
      }

      Map.put(positions, position_id, position)
    end
  end

  defp remaining_quantity(current_position, "CM", cum_qty) when not is_nil(current_position) do
    case {Integer.parse(Map.get(current_position, :size, "0")), Integer.parse(cum_qty)} do
      {{current, _}, {closed, _}} -> "#{max(0, current - closed)}"
      _ -> "0"
    end
  end

  defp remaining_quantity(_current_position, _ord_type, cum_qty), do: cum_qty

  defp open_price(field_map, msg) do
    case Base.parse_float(Map.get(field_map, "9121")) do
      price when price > 0 -> price
      _zero -> Map.get(msg, :settlement_price) || Map.get(msg, :settl_price)
    end
  end

  defp nonzero_or(value, fallback) when value == 0.0, do: fallback
  defp nonzero_or(value, _fallback), do: value

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_value), do: nil
end

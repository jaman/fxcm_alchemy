defmodule FxcmAlchemy.Session do
  @moduledoc """
  FXCM's login handshake and account discovery.

  Extends the plain-FIX `FixAlchemy.Session` with FXCM's post-logon flow: on
  logon (`A`) it sends UserRequest (`BE`); on UserResponse (`BF`) it sends
  CollateralInquiry (`BB`) unless the account is already known; on the ack (`BG`)
  the session is ready; on CollateralReport (`BA`) it learns the account and
  requests positions and orders.

  What a session does after logon follows from the roles it was started with:
  one serving `:trading` asks for its positions and orders, one serving
  `:market_data` asks for the security list.

  Only the login flow is overridden — subscription, dispatch, and the GenServer
  lifecycle come from the base.
  """

  use FixAlchemy.Session

  require Logger

  alias FixAlchemy.Client
  alias FixAlchemy.Parser

  @impl FixAlchemy.Session
  def message_types, do: ["A", "BF", "BG", "BA", "3"]

  @impl FixAlchemy.Session
  def init_session(opts) do
    %{
      connection_id: Keyword.fetch!(opts, :connection_id),
      session_name: Keyword.get(opts, :session_name, :trading),
      session_roles: Keyword.get(opts, :session_roles, [:trading, :market_data]),
      username: Keyword.get(opts, :username),
      password: Keyword.get(opts, :password),
      account: Keyword.get(opts, :account),
      user_on_login: Keyword.get(opts, :user_on_login, false),
      rejected: MapSet.new()
    }
  end

  @impl FixAlchemy.Session
  def handle_fix("A", _raw, meta, %{user_on_login: false} = state) do
    send_msg(meta.client, "BE", user_request(state))
    state
  end

  def handle_fix("A", _raw, meta, state), do: complete_login(state, meta.client)

  def handle_fix("BF", _raw, meta, state), do: complete_login(state, meta.client)

  def handle_fix("BG", _raw, meta, state), do: on_ready(state, meta.client)

  def handle_fix("BA", raw, meta, state) do
    account =
      case List.keyfind(Parser.split_fields(raw), "1", 0) do
        {"1", value} -> value
        nil -> state.account
      end

    state = %{state | account: account}
    trading_state(state, meta.client)
    if present?(account), do: Client.reach(meta.client, :account)
    state
  end

  def handle_fix("3", raw, meta, state) do
    case List.keyfind(Parser.split_fields(raw), "372", 0) do
      {"372", "BB"} ->
        on_ready(%{state | rejected: MapSet.put(state.rejected, "BB")}, meta.client)

      _other ->
        state
    end
  end

  def handle_fix(type, raw, meta, state), do: super(type, raw, meta, state)

  defp complete_login(state, client) do
    cond do
      MapSet.member?(state.rejected, "BB") ->
        on_ready(state, client)

      present?(state.account) ->
        on_ready(state, client)

      true ->
        send_msg(client, "BB", [{263, "1"}, {909, "3"}])
        state
    end
  end

  defp on_ready(state, client) do
    if serves_market_data?(state) do
      send_msg(client, "x", [
        {320, "instruments_#{System.system_time(:millisecond)}"},
        {559, "4"}
      ])
    end

    trading_state(state, client)
    Client.ready(client)
    if present?(state.account), do: Client.reach(client, :account)
    state
  end

  defp trading_state(state, client) do
    if :trading in state.session_roles and present?(state.account) do
      send_msg(client, "AN", positions_request(state.account))
      send_msg(client, "AF", orders_request())
    end

    state
  end

  defp serves_market_data?(state), do: :market_data in state.session_roles

  defp positions_request(account) do
    [
      {710, "pos_#{System.system_time(:millisecond)}"},
      {724, "0"},
      {263, "1"},
      {1, account},
      {60, timestamp()},
      {581, "1"},
      {715, DateTime.utc_now() |> DateTime.to_date() |> Date.to_iso8601(:basic)}
    ]
  end

  defp orders_request do
    [{584, "orders_#{System.system_time(:millisecond)}"}, {585, "7"}]
  end

  defp user_request(state) do
    [{553, state.username}, {554, state.password}, {923, "1"}, {924, "1"}]
  end

  defp send_msg(client, type, fields) do
    Client.send_custom_message(client, {type, fields})
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp timestamp do
    <<ret::binary-size(21), _::binary>> =
      DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H:%M:%S.%f")

    ret
  end
end

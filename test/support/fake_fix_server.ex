defmodule FxcmAlchemy.FakeFixServer do
  @moduledoc """
  Minimal in-process FIX counterparty for exercising the client over real TCP
  or TLS.

  Listens on an ephemeral port and accepts connections repeatedly. Every
  accepted connection is announced to the test process as
  `:fix_server_connected`, every framed inbound message as
  `{:server_received, message}`, and a peer disconnect as
  `:fix_server_disconnected`.

  Pass `ssl_opts: [cert: ..., key: ...]` to serve TLS instead of plain TCP.
  """

  use GenServer

  alias FixAlchemy.Parser

  @soh <<1>>

  @spec start_link(pid(), keyword()) :: GenServer.on_start()
  def start_link(test_pid, opts \\ []) do
    GenServer.start_link(__MODULE__, {test_pid, opts})
  end

  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @spec send_raw(GenServer.server(), binary()) :: :ok | {:error, term()}
  def send_raw(server, data), do: GenServer.call(server, {:send_raw, data})

  @spec build(binary(), [{binary(), binary()}]) :: binary()
  def build(msg_type, fields) do
    framed = frame(msg_type, fields)
    framed <> "10=#{Parser.calculate_checksum(framed)}#{@soh}"
  end

  @spec build_with_checksum(binary(), [{binary(), binary()}], binary()) :: binary()
  def build_with_checksum(msg_type, fields, checksum) do
    frame(msg_type, fields) <> "10=#{checksum}#{@soh}"
  end

  @impl true
  def init({test_pid, opts}) do
    listen_opts = [:binary, active: false, reuseaddr: true]

    {transport, listen_socket, port} =
      case Keyword.get(opts, :ssl_opts) do
        nil ->
          {:ok, socket} = :gen_tcp.listen(0, listen_opts)
          {:ok, port} = :inet.port(socket)
          {:gen_tcp, socket, port}

        ssl_opts ->
          {:ok, socket} = :ssl.listen(0, listen_opts ++ ssl_opts)
          {:ok, {_address, port}} = :ssl.sockname(socket)
          {:ssl, socket, port}
      end

    server = self()
    {:ok, _acceptor} = Task.start_link(fn -> accept_loop(transport, listen_socket, server) end)

    {:ok, %{transport: transport, port: port, socket: nil, test_pid: test_pid, buffer: <<>>}}
  end

  @impl true
  def handle_info({:accepted, socket}, state) do
    setopts(state.transport, socket, active: true)
    send(state.test_pid, :fix_server_connected)
    {:noreply, %{state | socket: socket, buffer: <<>>}}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state), do: handle_data(data, state)

  @impl true
  def handle_info({:ssl, _socket, data}, state), do: handle_data(data, state)

  @impl true
  def handle_info({:tcp_closed, _socket}, state), do: handle_closed(state)

  @impl true
  def handle_info({:ssl_closed, _socket}, state), do: handle_closed(state)

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def handle_call({:send_raw, data}, _from, state) do
    {:reply, state.transport.send(state.socket, data), state}
  end

  defp handle_data(data, state) do
    {buffer, messages} = Parser.parse(state.buffer <> data)
    Enum.each(messages, &send(state.test_pid, {:server_received, &1}))
    {:noreply, %{state | buffer: buffer}}
  end

  defp handle_closed(state) do
    send(state.test_pid, :fix_server_disconnected)
    {:noreply, %{state | socket: nil}}
  end

  defp setopts(:gen_tcp, socket, opts), do: :inet.setopts(socket, opts)
  defp setopts(:ssl, socket, opts), do: :ssl.setopts(socket, opts)

  defp frame(msg_type, fields) do
    body =
      ([{"35", msg_type}, {"49", "FAKE"}, {"56", "TESTCLIENT"}] ++ fields)
      |> Enum.map_join(@soh, fn {tag, value} -> "#{tag}=#{value}" end)

    body = body <> @soh
    "8=FIX.4.4#{@soh}9=#{byte_size(body)}#{@soh}#{body}"
  end

  defp accept_loop(:gen_tcp, listen_socket, server) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        :ok = :gen_tcp.controlling_process(socket, server)
        send(server, {:accepted, socket})
        accept_loop(:gen_tcp, listen_socket, server)

      {:error, _reason} ->
        :ok
    end
  end

  defp accept_loop(:ssl, listen_socket, server) do
    with {:ok, transport_socket} <- :ssl.transport_accept(listen_socket),
         {:ok, socket} <- :ssl.handshake(transport_socket) do
      :ok = :ssl.controlling_process(socket, server)
      send(server, {:accepted, socket})
      accept_loop(:ssl, listen_socket, server)
    else
      {:error, _reason} -> :ok
    end
  end
end

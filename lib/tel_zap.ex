defmodule TelZap do
  require Logger
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      module: {TelZap.accept(4000), []}
    ]

    opts = [strategy: :one_for_one, name: TelZap.Supervisor]
    Supervisor.start_link(children, opts)
    {:ok, self()}
  end

  def accept(port) do
    {:ok, socket} = :gen_tcp.listen(port, [:binary, packet: :line, active: false])
    {:ok, client_pid} = TelZap.Clients.start_link()
    {:ok, badguys_pid} = TelZap.BadGuys.start_link()

    Logger.info("Listening on port #{port}")
    loop_acceptor(socket, client_pid, badguys_pid)
  end

  def loop_acceptor(socket, client_pid, badguys_pid) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        spawn(__MODULE__, :accept_client, [client, client_pid, badguys_pid])

      {:error, reason} ->
        Logger.error("Could not connect for reason: #{reason} shutting down client ")
    end

    loop_acceptor(socket, client_pid, badguys_pid)
  end

  def accept_client(client, client_pid, badguys_pid) do
    peer = peer_name(client)

    case GenServer.call(badguys_pid, {:is_banned, peer}) do
      {:yes, time} ->
        for_ = time - :os.system_time(:millisecond)
        Logger.info("Client #{peer} is banned, closing connection")
        :gen_tcp.send(client, "You are banned for #{for_} #\n")
        :gen_tcp.close(client)

      _ ->
        Logger.info("Accepted connection from #{peer}")
        GenServer.call(client_pid, {:add, client})
        :gen_tcp.send(client, "Welcome to TelZap, #{peer}\n")
        connect(client, client_pid, badguys_pid)
    end
  end

  def connect(client, client_pid, badguys_pid) do
    peer = peer_name(client)
    strike? = strike?(client, client_pid)
    GenServer.call(client_pid, {:update, client})

    case :gen_tcp.recv(client, 0) do
      {:ok, message} ->
        case strike? do
          :yes ->
            GenServer.call(badguys_pid, {:try_ban, peer, 10_000})

            case GenServer.call(badguys_pid, {:is_banned, peer}) do
              {:yes, time} ->
                for_ = time - :os.system_time(:millisecond)
                Logger.info("Client #{peer} is banned, closing connection")
                :gen_tcp.send(client, "You are banned for #{for_} #\n")
                :gen_tcp.close(client)

              _ ->
                Logger.info("Strinking client #{peer} ")
                :gen_tcp.send(client, "You are typing too fast, slow down\n")
                connect(client, client_pid, badguys_pid)
            end

          :no ->
            Logger.info("Received message from #{peer}: #{message}")
            GenServer.call(client_pid, {:broadcast, message, client})
            connect(client, client_pid, badguys_pid)
        end

      {:error, reason} ->
        case reason do
          :closed ->
            Logger.info("Connection closed by #{peer}")
            GenServer.call(client_pid, {:remove, client})
            :gen_tcp.close(client)

          :timeout ->
            Logger.info("Connection timeout by #{peer}")
            GenServer.call(client_pid, {:remove, client})
            :gen_tcp.close(client)

          _ ->
            Logger.error("Could not receive message from #{peer}: #{inspect(reason)}")
            GenServer.call(client_pid, {:remove, client})
            :gen_tcp.close(client)
        end
    end
  end

  def peer_name(client) do
    case :inet.peername(client) do
      {:ok, {ip, _}} ->
        "#{:inet_parse.ntoa(ip)}"

      {:error, reason} ->
        Logger.error("Could not get peer name: #{inspect(reason)}")
        :gen_tcp.close(client)
    end
  end

  def strike?(client, client_pid) do
    now = :os.system_time(:millisecond)
    last_message = GenServer.call(client_pid, {:last_message, client})

    case last_message do
      0 ->
        :no

      _ when now - last_message < 1000 ->
        :yes

      _ ->
        :no
    end
  end
end

defmodule TelZap.Clients do
  use GenServer

  def start_link do
    GenServer.start_link(__MODULE__, %{})
  end

  def init(state) do
    {:ok, state}
  end

  def handle_call({:add, client}, _from, state) do
    {:reply, :ok, Map.put(state, client, 0)}
  end

  def handle_call({:remove, client}, _from, state) do
    {:reply, :ok, Map.delete(state, client)}
  end

  def handle_call({:update, client}, _from, state) do
    {:reply, :ok, Map.put(state, client, :os.system_time(:millisecond))}
  end

  def handle_call({:last_message, client}, _from, state) do
    {:reply, Map.get(state, client), state}
  end

  def handle_call({:broadcast, message, sender}, _from, state) do
    Enum.each(state, fn {client, _} ->
      if client != sender do
        :gen_tcp.send(client, message)
      end
    end)

    {:reply, :ok, state}
  end
end

defmodule TelZap.BadGuys do
  use GenServer

  def start_link do
    GenServer.start_link(__MODULE__, %{})
  end

  def init(state) do
    {:ok, state}
  end

  def handle_call({:is_banned, client}, _from, state) do
    case Map.get(state, client) do
      {secs, amount_strikes} when amount_strikes >= 3 ->
        if secs > :os.system_time(:millisecond) do
          {:reply, {:yes, secs}, state}
        else
          {:reply, {:no}, state}
        end

      _ ->
        {:reply, {:no}, state}
    end
  end

  def handle_call({:try_ban, client, secs}, _from, state) do
    until = :os.system_time(:millisecond) + secs

    case Map.get(state, client) do
      nil ->
        {:reply, :ok, Map.put(state, client, {until, 1})}

      {_, amount_strikes} when amount_strikes < 3 ->
        {:reply, :ok, Map.put(state, client, {until, amount_strikes + 1})}

      {_, amount_strikes} when amount_strikes >= 3 ->
        {:reply, :ok, Map.put(state, client, {until, 1})}
    end
  end
end

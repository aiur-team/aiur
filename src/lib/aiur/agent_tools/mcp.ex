defmodule Aiur.AgentTools.MCP do
  @moduledoc "A session-scoped MCP endpoint for Aiur coordination tools."

  use GenServer

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.AgentTools.MCP.Router
  alias Aiur.AppServer.ToolCallLedger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec connection(pid()) :: map() | {:error, :unauthorized}
  def connection(server), do: GenServer.call(server, :connection)

  @spec bind(pid(), term()) :: {:ok, reference()} | {:error, atom()}
  def bind(server, attempt), do: GenServer.call(server, {:bind, attempt})

  @spec unbind(pid(), reference()) :: :ok | {:error, atom()}
  def unbind(server, binding), do: GenServer.call(server, {:unbind, binding})

  @spec stop(pid()) :: :ok | {:error, :unauthorized}
  def stop(server), do: GenServer.call(server, :stop)

  @doc "Execute a tagged MCP request in the runner owner process."
  @spec execute_request(pid(), tuple(), (String.t(), map() -> map())) :: :ok | {:error, atom()}
  def execute_request(server, {:aiur_mcp_call, server, reply_to, ref, binding, invocation, name, args}, executor)
      when is_function(executor, 2) do
    result =
      case GenServer.call(server, {:valid_binding, binding}) do
        :ok -> execute(invocation, name, args, executor)
        error -> error
      end

    send(reply_to, {:aiur_mcp_reply, ref, result})
    :ok
  catch
    :exit, _ -> {:error, :gateway_unavailable}
  end

  def execute_request(_server, _message, _executor), do: {:error, :invalid_request}

  @doc false
  @spec authorize(pid(), String.t() | nil) :: boolean()
  def authorize(server, token), do: GenServer.call(server, {:authorize, token})

  @doc false
  @spec dispatch(pid(), integer() | String.t(), String.t(), map()) ::
          {:ok, reference(), pid()} | {:error, atom()}
  def dispatch(server, id, name, args), do: GenServer.call(server, {:dispatch, self(), id, name, args})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    if owner != self(), do: Process.monitor(owner)
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    case Bandit.start_link(
           plug: {Router, server: self()},
           scheme: :http,
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false,
           thousand_island_options: [num_acceptors: 1, num_connections: 32]
         ) do
      {:ok, listener} ->
        case ThousandIsland.listener_info(listener) do
          {:ok, {_ip, port}} ->
            {:ok, %{owner: owner, listener: listener, port: port, token: token, id: id, binding: nil, requests: %{}}}

          _ ->
            Process.exit(listener, :shutdown)
            {:stop, :listener_info_unavailable}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:connection, {owner, _}, %{owner: owner} = state) do
    {:reply,
     %{
       "transport" => "streamableHttp",
       "url" => "http://127.0.0.1:#{state.port}/mcp",
       "headers" => %{"Authorization" => "Bearer #{state.token}"},
       "mode" => "required"
     }, state}
  end

  def handle_call(:connection, _from, state), do: {:reply, {:error, :unauthorized}, state}

  def handle_call(:stop, {owner, _}, %{owner: owner} = state), do: {:stop, :normal, :ok, state}
  def handle_call(:stop, _from, state), do: {:reply, {:error, :unauthorized}, state}

  def handle_call({:bind, attempt}, {owner, _}, %{owner: owner, binding: nil} = state)
      when not is_nil(attempt) do
    binding = make_ref()
    {:reply, {:ok, binding}, %{state | binding: {binding, attempt}}}
  end

  def handle_call({:bind, _}, _from, state), do: {:reply, {:error, :unauthorized}, state}

  def handle_call({:unbind, binding}, {owner, _}, %{owner: owner, binding: {binding, _}} = state) do
    {:reply, :ok, %{state | binding: nil}}
  end

  def handle_call({:unbind, _}, _from, state), do: {:reply, {:error, :unauthorized}, state}

  def handle_call({:valid_binding, binding}, {owner, _}, %{owner: owner, binding: {binding, _}} = state),
    do: {:reply, :ok, state}

  def handle_call({:valid_binding, _}, _from, state), do: {:reply, {:error, :inactive_attempt}, state}

  def handle_call({:authorize, token}, _from, state) do
    valid =
      is_binary(token) and byte_size(token) == byte_size(state.token) and
        Plug.Crypto.secure_compare(token, state.token)

    {:reply, valid, state}
  end

  def handle_call({:dispatch, reply_to, id, name, args}, _from, %{binding: {binding, _attempt}} = state)
      when is_binary(name) and is_map(args) do
    fingerprint = :crypto.hash(:sha256, :erlang.term_to_binary({name, args}, [:deterministic]))

    case Map.get(state.requests, id) do
      nil ->
        if map_size(state.requests) >= 10_000 do
          {:reply, {:error, :gateway_capacity}, state}
        else
          ref = make_ref()
          invocation = {state.id, id}
          send(state.owner, {:aiur_mcp_call, self(), reply_to, ref, binding, invocation, name, args})
          {:reply, {:ok, ref, state.owner}, put_in(state.requests[id], {binding, fingerprint})}
        end

      {^binding, ^fingerprint} ->
        ref = make_ref()
        invocation = {state.id, id}
        send(state.owner, {:aiur_mcp_call, self(), reply_to, ref, binding, invocation, name, args})
        {:reply, {:ok, ref, state.owner}, state}

      {^binding, _} ->
        {:reply, {:error, :conflicting_invocation}, state}

      _ ->
        {:reply, {:error, :stale_invocation}, state}
    end
  end

  def handle_call({:dispatch, _, _, _, _}, _from, state),
    do: {:reply, {:error, :inactive_attempt}, state}

  @impl true
  def handle_info({:DOWN, _, :process, owner, _}, %{owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info({:EXIT, listener, _}, %{listener: listener} = state),
    do: {:stop, :listener_stopped, %{state | listener: nil}}

  @impl true
  def terminate(_reason, %{listener: listener}) when is_pid(listener) do
    Process.unlink(listener)
    Process.exit(listener, :shutdown)
  end

  def terminate(_, _), do: :ok

  @impl true
  def format_status(status) when is_map(status) do
    Map.new(status, fn
      {:state, state} -> {:state, Map.take(state, [:owner, :listener, :port])}
      {:message, _} -> {:message, :redacted}
      other -> other
    end)
  end

  defp execute(invocation, name, args, executor) do
    fingerprint = :crypto.hash(:sha256, :erlang.term_to_binary({name, args}, [:deterministic]))

    ToolCallLedger.execute({:muse_mcp, invocation}, fingerprint, fn ->
      ToolExecutor.execute(executor, name, args, invocation)
    end)
  end
end

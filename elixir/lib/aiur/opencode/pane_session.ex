defmodule Aiur.Opencode.PaneSession do
  @moduledoc false

  use GenServer
  require Logger

  alias Aiur.Opencode.{ApiClient, Config, PaneSupervisor, Protocol, Server, TokenRegistry, WorkspaceSetup}

  defstruct [:identifier, :workspace, :server, :base_url, :session_id, :token, :attach_command]

  @spec start(String.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def start(identifier, workspace) when is_binary(identifier) and is_binary(workspace) do
    child = {__MODULE__, %{identifier: identifier, workspace: workspace}}

    case DynamicSupervisor.start_child(PaneSupervisor, child) do
      {:ok, pid} -> safe_await_ready(pid)
      {:error, {:already_started, pid}} -> safe_await_ready(pid)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via(Map.fetch!(opts, :identifier)))

  @spec await_ready(pid()) :: {:ok, map()} | {:error, term()}
  def await_ready(pid), do: GenServer.call(pid, :await_ready, 30_000)

  # Caller runs inside PaneManager's call handler; an exit here crashes PaneManager and panes stop opening.
  defp safe_await_ready(pid) do
    await_ready(pid)
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  def init(%{identifier: identifier, workspace: workspace}) do
    send(self(), :boot)
    {:ok, %__MODULE__{identifier: identifier, workspace: workspace}}
  end

  @impl true
  def handle_call(:await_ready, _from, %{attach_command: command, session_id: session_id, base_url: base_url} = state)
      when is_binary(command) do
    {:reply, {:ok, %{attach_command: command, session_id: session_id, attach_url: base_url}}, state}
  end

  def handle_call(:await_ready, from, state) do
    Process.send_after(self(), {:reply_later, from}, 50)
    {:noreply, state}
  end

  @impl true
  def handle_info(:boot, state) do
    token = random_token()
    bridge_url = "http://#{Config.bridge_host()}:#{Config.bridge_port()}"

    with {:ok, _} <- WorkspaceSetup.materialize(state.workspace, state.identifier, bridge_url, token),
         {:ok, server} <- Server.start_link(%{identifier: state.identifier, workspace: state.workspace}),
         {:ok, base_url, _os_pid} <- Server.await_ready(server),
         {:ok, session} <- ApiClient.create_session(base_url, state.identifier),
         session_id when is_binary(session_id) <- session_id_from(session) do
      # Per-identifier transcript writing now lives in `Aiur.Opencode.SessionWriter`,
      # spawned via `SessionWriterRegistry.ensure/2` from the PaneManager open path.
      attach_command = Protocol.attach_command(base_url, session_id)
      Logger.info("opencode_pane ready issue_identifier=#{state.identifier} session_id=#{session_id}")
      {:noreply, %{state | server: server, base_url: base_url, session_id: session_id, token: token, attach_command: attach_command}}
    else
      reason ->
        Logger.warning("opencode_pane start_failed issue_identifier=#{state.identifier} reason=#{inspect(reason)}")
        {:stop, {:shutdown, reason}, state}
    end
  end

  def handle_info({:reply_later, from}, state) do
    if is_binary(state.attach_command) do
      GenServer.reply(from, {:ok, %{attach_command: state.attach_command, session_id: state.session_id, attach_url: state.base_url}})
    else
      Process.send_after(self(), {:reply_later, from}, 50)
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if is_binary(state.token), do: TokenRegistry.delete(state.token, Config.safe_identifier(state.identifier))
    if is_pid(state.server), do: GenServer.stop(state.server)
    :ok
  end

  defp via(identifier), do: {:via, Registry, {Aiur.Opencode.PaneRegistry, identifier}}

  defp session_id_from(%{"id" => id}) when is_binary(id), do: id
  defp session_id_from(%{"session" => %{"id" => id}}) when is_binary(id), do: id
  defp session_id_from(%{id: id}) when is_binary(id), do: id
  defp session_id_from(_), do: nil

  defp random_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end

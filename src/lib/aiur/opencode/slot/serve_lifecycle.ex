defmodule Aiur.Opencode.Slot.ServeLifecycle do
  @moduledoc """
  Serve-generation lifecycle: boot, teardown, and cleanup.

  Plain function module — no processes started here except the Task.start
  inside `maybe_run_session_gc/1` and the supervised Server.start_link call.
  """

  require Logger

  alias Aiur.Opencode.Slot.AttachPane

  alias Aiur.Opencode.{
    ApiClient,
    Config,
    Server,
    SessionGC,
    SessionSupervisor,
    SessionWriterRegistry,
    TokenRegistry,
    WorkspaceSetup
  }

  # Pull the orchestrator's currently-active identifier list. The
  # orchestrator starts agents asynchronously after the slot supervisor
  # starts, so the list may be empty when the first slot boots. Poll
  # briefly (up to ~3 s) waiting for at least one agent so the
  # pre-warmed serve includes a useful models map and the first open
  # hits the warm path. If still empty after the budget, proceed with
  # an empty map — first open will pay the identifier_miss rebuild.
  @orchestrator_wait_budget_ms 3_000
  @orchestrator_poll_interval_ms 100

  @doc """
  Boot the opencode serve for a slot generation.

  Reads `state.workspace_path`, `state.slot_index`, `state.generation`.
  Returns `{:ok, server_pid, base_url, token}` on success or `{:error, reason}`.
  """
  @spec boot(map(), [String.t()], keyword()) ::
          {:ok, pid(), String.t(), String.t()} | {:error, term()}
  def boot(state, agent_ids, display_opt) do
    serve_span = Aiur.Perf.span_begin(:slot_start_serve, slot: state.slot_index)
    Process.put(:slot_serve_span, serve_span)
    bridge_url = "http://#{Config.bridge_host()}:#{Config.bridge_port()}"

    with :ok <- File.mkdir_p(state.workspace_path),
         {:ok, token} <-
           WorkspaceSetup.materialize_slot(
             state.workspace_path,
             bridge_url,
             agent_ids,
             state.slot_index,
             state.generation,
             display_opt
           ),
         {:ok, server_pid} <-
           Server.start_link(%{
             identifier: "_slot-#{state.slot_index}",
             workspace: state.workspace_path
           }),
         {:ok, base_url, _os_pid} <- Server.await_ready(server_pid) do
      Logger.info("opencode_slot phase=serve_ready elapsed_ms=#{Aiur.Boot.elapsed_ms()} slot=#{state.slot_index} base_url=#{base_url}")

      if span = Process.get(:slot_serve_span) do
        Aiur.Perf.span_end(span, slot: state.slot_index, base_url: base_url)
        Process.delete(:slot_serve_span)
      end

      {:ok, server_pid, base_url, token}
    else
      error ->
        Logger.warning("opencode_slot phase=serve_failed elapsed_ms=#{Aiur.Boot.elapsed_ms()} slot=#{state.slot_index} reason=#{inspect(error)}")

        {:error, error}
    end
  end

  @doc "Poll the orchestrator for currently-active agent identifiers."
  @spec safely_list_active_identifiers() :: [String.t()]
  def safely_list_active_identifiers do
    do_wait_for_active_identifiers(0)
  end

  @doc """
  Tear down the serve, pane, and token for a generation before rebuilding.

  Preserves this exact order and every comment (#372; giant-slot.md §4 risk 3):
  reap writers → stop server → kill pane (unregister: false) → delete token.
  """
  @spec teardown_generation(map()) :: :ok
  def teardown_generation(state) do
    # Reap writers bound to the OLD base_url before tearing the serve
    # down. The rebuild gives this slot a fresh base_url, so a writer
    # left pointing at the old generation (e.g. the displaced leadoff
    # identifier when a surplus slot is reclaimed for a post-boot agent)
    # would otherwise post turn markers into the dead serve forever
    # (#372). Done first so DELETE /session reaches a still-live serve.
    reap_writers_for_base_url(state.base_url)

    # Tear down the existing serve + pane. Bump generation + delete
    # the old token so the bridge can't accept stale auth from a
    # still-running opencode process after we replace it.
    if is_pid(state.server_pid) and Process.alive?(state.server_pid) do
      _ = GenServer.stop(state.server_pid, :normal, 1_000)
    end

    # Kill the old attach pane NOW (before we clear state.pane_id below)
    # so the hidden window's pane budget stays bounded across rebuilds.
    # Without this, every identifier_miss leaks a tmux pane; once the
    # window hits its 6-pane cap the next `split_pane` fails with
    # `no space for new pane` and the rebuild silently aborts.
    if is_binary(state.pane_id), do: AttachPane.kill(state.pane_id, unregister: false)

    if is_binary(state.token), do: TokenRegistry.delete(state.token)

    :ok
  end

  @doc """
  Full cleanup on slot termination.

  token delete → reap writers → noproc-tolerant server stop → kill pane.
  """
  @spec terminate_cleanup(map()) :: :ok
  def terminate_cleanup(state) do
    if is_binary(state.token), do: TokenRegistry.delete(state.token)

    # Reap any SessionWriters tied to this slot's base_url. Without this,
    # rebuilt slots (generation bump → new base_url) leak the previous
    # generation's writers and their opencode sessions stay orphaned in
    # the shared SQLite DB. The writers also hold connection pool slots
    # against a now-dead serve.
    reap_writers_for_base_url(state.base_url)

    # A noproc here (server already down) must not skip the pane reap below.
    if is_pid(state.server_pid) do
      try do
        GenServer.stop(state.server_pid)
      catch
        :exit, _ -> :ok
      end
    end

    if is_binary(state.pane_id), do: AttachPane.kill(state.pane_id)

    :ok
  end

  @doc """
  Select the SessionWriter registry entries bound to `base_url`. Pure
  filter, extracted so the reap selection — only this slot's writers,
  never another live slot's — is unit-testable without a live registry.
  Each slot's serve owns a unique base_url, so matching on it cannot
  reap a sibling slot's writers.
  """
  @spec writers_for_base_url([%{base_url: String.t()}], String.t()) :: [%{base_url: String.t()}]
  def writers_for_base_url(entries, base_url) do
    Enum.filter(entries, fn entry -> entry.base_url == base_url end)
  end

  @doc "Run boot-time SessionGC only on slot 1. The Task.start is the only allowed one in slot/."
  @spec maybe_run_session_gc(map()) :: :ok
  def maybe_run_session_gc(%{slot_index: 1, base_url: base_url}) do
    Task.start(fn -> SessionGC.run(base_url) end)
    :ok
  end

  def maybe_run_session_gc(_state), do: :ok

  @doc "Derive the on-disk workspace path for a slot index."
  @spec workspace_path_for(integer()) :: String.t()
  def workspace_path_for(slot_index) do
    base = System.user_home!()
    Path.join([base, ".local/share/aiur/opencode-slot-#{slot_index}"])
  end

  defp reap_writers_for_base_url(base_url) when is_binary(base_url) do
    SessionWriterRegistry.all()
    |> writers_for_base_url(base_url)
    |> Enum.each(&reap_session_writer(&1, base_url))

    :ok
  end

  defp reap_writers_for_base_url(_), do: :ok

  defp reap_session_writer(%{writer_pid: pid, session_id: session_id}, base_url) do
    _ = ApiClient.delete_session(base_url, session_id)

    if is_pid(pid) and Process.alive?(pid) do
      _ = DynamicSupervisor.terminate_child(SessionSupervisor, pid)
    end

    :ok
  end

  defp do_wait_for_active_identifiers(waited_ms) when waited_ms >= @orchestrator_wait_budget_ms do
    fetch_active_identifiers()
  end

  defp do_wait_for_active_identifiers(waited_ms) do
    case fetch_active_identifiers() do
      [] ->
        Process.sleep(@orchestrator_poll_interval_ms)
        do_wait_for_active_identifiers(waited_ms + @orchestrator_poll_interval_ms)

      ids ->
        ids
    end
  end

  defp fetch_active_identifiers do
    Aiur.Orchestrator.list_active_identifiers(Aiur.Orchestrator, 500)
  rescue
    _ -> []
  catch
    _, _ -> []
  end
end

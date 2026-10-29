defmodule Aiur.RepoBase do
  @moduledoc """
  Maintains one warm, pre-compiled base checkout of the target repo's configured `tracker.base_branch` at
  `~/.aiur/repo/<owner>/<name>/latest` so per-issue workspaces materialize from it
  (copy-on-write) instead of cold-cloning + recompiling on every dispatch.
  Builds run asynchronously in a spawned worker so the GenServer mailbox stays responsive — the orchestrator's
  eager-dispatch gate reads `status/0` rather than blocking on a build. The build command is the repo-agnostic
  `prewarm.base_build` filled by toolchain detection at `aiur init`.
  `_build`/deps are gitignored, so `reset --hard origin/<base>` updates tracked
  source but leaves build artifacts — refreshes are incremental.
  On every base-branch advance the base is rebuilt; a newer advance detected mid-build (via `git ls-remote`,
  which never touches the base working tree) PREEMPTS the in-flight build so workspaces never spin off a stale base.
  Phase events (`:cloning` -> `:fetching` -> `:building` -> `:ready` / `{:error, _}`) are broadcast for the agent-list loading bar.
  """

  use GenServer
  require Logger

  import Aiur.RepoBase.Probe
  import Aiur.RepoBase.Watchdog

  alias Aiur.AgentPubSub
  alias Aiur.Config
  alias Aiur.Config.Paths
  alias Aiur.RepoBase.BuildProcess
  alias Aiur.RepoBase.BuildTimeout
  alias Aiur.RepoBase.Clone
  alias Aiur.RepoBase.Migration
  alias Aiur.RepoBase.Preparer
  alias Aiur.RepoBase.Settings
  alias Aiur.RepoBase.StateTree

  # The probe owns its 30-second timeout. The idle watchdog releases holds whose
  # completion signal was lost; a separate total build deadline bounds even a
  # live but wedged build and releases dispatch for cold-clone fallback.
  @dispatch_hold_timeout_ms 600_000
  @build_hold_timeout_ms 3_600_000

  ## ---- Public API ----

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Absolute path of the warm base for `repo_url`."
  @spec base_path(String.t()) :: Path.t()
  def base_path(repo_url) when is_binary(repo_url), do: Path.join(repo_path(repo_url), "latest")

  @doc false
  @spec cache_sidecar_paths(Path.t()) :: [Path.t()]
  defdelegate cache_sidecar_paths(root), to: Paths, as: :repo_cache_sidecar_paths

  @doc "Absolute root beneath which every per-repository state node lives."
  @spec state_root() :: Path.t()
  def state_root, do: base_root()
  @doc "Absolute path of the per-repository state node for `repo_url`."
  @spec repo_path(String.t()) :: Path.t()
  defdelegate repo_path(repo_url), to: Paths, as: :repo_state_path

  @doc "Path of the per-repository state node relative to its owning home directory."
  @spec repo_relative_path(String.t()) :: Path.t()
  defdelegate repo_relative_path(repo_url), to: Paths, as: :repo_state_relative_path

  @doc "Absolute path of the build-order store for `repo_url`."
  @spec builds_path(String.t()) :: Path.t()
  def builds_path(repo_url) when is_binary(repo_url), do: Path.join(repo_path(repo_url), "builds")

  @doc "Absolute path of executor-authored repository metadata for `repo_url`."
  @spec meta_path(String.t()) :: Path.t()
  def meta_path(repo_url) when is_binary(repo_url), do: Path.join(repo_path(repo_url), "meta")

  @doc "Absolute path of the append-only executor findings file for `repo_url`."
  @spec findings_path(String.t()) :: Path.t()
  def findings_path(repo_url) when is_binary(repo_url), do: Path.join(meta_path(repo_url), "findings.ndjson")

  @doc "Absolute path of the append-only Executor-to-operator asks file for `repo_url`."
  @spec asks_path(String.t()) :: Path.t()
  def asks_path(repo_url) when is_binary(repo_url), do: Path.join(meta_path(repo_url), "asks.ndjson")

  @doc "Absolute path of per-boot executor retrospectives for `repo_url`."
  @spec retros_path(String.t()) :: Path.t()
  def retros_path(repo_url) when is_binary(repo_url), do: Path.join(meta_path(repo_url), "retros")

  @doc "Absolute path of regenerable analytics outputs for `repo_url`."
  @spec analytics_path(String.t()) :: Path.t()
  def analytics_path(repo_url) when is_binary(repo_url), do: Path.join(repo_path(repo_url), "analytics")

  @spec experiments_path(String.t()) :: Path.t()
  def experiments_path(repo_url), do: Path.join(repo_path(repo_url), "experiments")

  @doc "Absolute path of replaceable Executor state for `repo_url`."
  @spec executor_path(String.t()) :: Path.t()
  def executor_path(repo_url) when is_binary(repo_url), do: Path.join(repo_path(repo_url), "executor")

  @doc "Absolute path of the current Executor handoff for `repo_url`."
  @spec handoff_path(String.t()) :: Path.t()
  def handoff_path(repo_url) when is_binary(repo_url), do: Path.join(executor_path(repo_url), "handoff.md")

  @doc "Creates the canonical repository state tree before any writer needs it."
  @spec ensure_state_tree(String.t()) :: :ok | {:error, term()}
  def ensure_state_tree(repo_url) when is_binary(repo_url) do
    with :ok <- Migration.migrate_legacy_layout(base_path(repo_url)) do
      StateTree.ensure_state_tree_at(repo_path(repo_url))
    end
  end

  @doc """
  Creates the canonical repository state tree and imports the previous worktree
  retrospective once when it exists. The source remains untouched: it belongs to
  an old branch and this import is a durable machine-local copy.
  """
  @spec setup_state(String.t(), Path.t() | nil) :: :ok | {:error, term()}
  def setup_state(repo_url, source_root \\ nil) when is_binary(repo_url) do
    case ensure_state_tree(repo_url) do
      :ok -> Migration.import_legacy_retrospective(retros_path(repo_url), source_root)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Current base status as `{phase, base_path | nil}`. Fast and non-blocking —
  the orchestrator gate and the loading UI read this. `phase` is `:idle`,
  `:cloning`, `:fetching`, `:building`, `:checking`, `:ready`, or
  `{:error, reason}`.
  """
  @spec status(timeout()) :: {atom() | {:error, term()}, Path.t() | nil}
  def status(timeout \\ 5_000), do: GenServer.call(__MODULE__, :status, timeout)

  @doc """
  Trigger an asynchronous refresh of the warm base toward the latest remote base branch.
  No-op when pre-warm is disabled / unconfigured. Safe to call every poll cycle:
  rebuilds only when the base branch advanced, and preempts an in-flight build when it
  has. Returns immediately.
  """
  @spec refresh_async() :: :ok
  def refresh_async, do: GenServer.cast(__MODULE__, :refresh_async)

  @doc false
  @spec refresh_for_dispatch() :: atom() | {:error, term()}
  def refresh_for_dispatch, do: GenServer.call(__MODULE__, :refresh_for_dispatch)

  @doc """
  The branch the warm base tracks. Missing or empty `tracker.base_branch`
  configuration raises instead of guessing a destructive default.
  """
  @spec base_branch() :: String.t()
  def base_branch, do: Config.base_branch()

  ## ---- Synchronous core (no GenServer; exercised directly in tests) ----

  @doc """
  Ensures `base_path` is a clone of `repo_url` at the latest remote base branch, running
  `base_build` on first build and after every base-branch advance. Emits phase events
  as it progresses. Returns `{:ok, base_path}` or `{:error, reason}`.
  """
  @spec refresh(Path.t(), String.t(), String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def refresh(base_path, repo_url, base_build) do
    case run_refresh_steps(base_path, repo_url, base_build) do
      {:ok, _} = ok ->
        emit(:ready)
        ok

      {:error, reason} = err ->
        log_and_emit_error(reason)
        err
    end
  end

  defp run_refresh_steps(base_path, repo_url, base_build) do
    with {:ok, changed?} <- Preparer.prepare(base_path, repo_url) do
      Clone.maybe_build(base_path, base_build, changed? or not Clone.built?(base_path, base_build))
    end
  end

  ## ---- GenServer ----

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    schedule_poll()

    {:ok,
     %{
       phase: :idle,
       base_path: nil,
       build: nil,
       probe: nil,
       ready_head: nil,
       freshness: :unknown,
       remote_head_fun: Keyword.get(opts, :remote_head_fun, &Clone.remote_head/1),
       dispatch_hold_timeout_ms: Keyword.get(opts, :dispatch_hold_timeout_ms, @dispatch_hold_timeout_ms),
       build_hold_timeout_ms: Keyword.get(opts, :build_hold_timeout_ms, @build_hold_timeout_ms),
       build_hold_timeout_ms_override: Keyword.get(opts, :build_hold_timeout_ms),
       dispatch_watchdog: nil
     }}
  end

  @impl true
  def terminate(_reason, state), do: BuildProcess.terminate(state)

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {state.phase, state.base_path}, state}
  end

  def handle_call({:build_os_process, pid, event, os_pid, group_id, identity}, _from, %{build: %{pid: pid}} = state) do
    {:reply, :ok, BuildProcess.update_process(state, event, os_pid, group_id, identity)}
  end

  def handle_call({:build_os_process, _pid, _event, _os_pid, _group_id, _identity}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:refresh_for_dispatch, _from, state) do
    state = do_refresh_for_dispatch(state)
    {:reply, state.phase, state}
  end

  @impl true
  def handle_cast(:refresh_async, state) do
    {:noreply, do_refresh_async(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    state = do_refresh_async(state)
    schedule_poll()
    {:noreply, state}
  end

  # The build worker reports the head it locked in before the (expensive) build,
  # so a later ls-remote probe can tell whether the base branch advanced past it.
  def handle_info({:build_head, pid, head}, %{build: %{pid: pid} = build} = state) do
    {:noreply, %{state | build: %{build | head: head}}}
  end

  def handle_info({:build_head, _pid, _head}, state), do: {:noreply, state}

  def handle_info({:build_done, pid, head, result}, %{build: %{pid: pid, ref: ref, timer: timer}} = state) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    Process.demonitor(ref, [:flush])
    state = %{state | build: nil}

    case result do
      {:ok, base} ->
        {:noreply, state |> Map.merge(%{phase: :ready, base_path: base, ready_head: head, freshness: :unknown}) |> clear_released_watchdog()}

      {:error, reason} ->
        {:noreply, state |> Map.put(:phase, {:error, reason}) |> clear_dispatch_watchdog()}
    end
  end

  def handle_info({:build_done, _pid, _head, _result}, state), do: {:noreply, state}

  # The build worker crashed without a clean :build_done.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{build: %{ref: ref, timer: timer}} = state) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    log_and_emit_error({:build_crashed, reason})

    {:noreply,
     state
     |> Map.merge(%{build: nil, phase: {:error, {:build_crashed, reason}}})
     |> clear_dispatch_watchdog()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{probe: %{ref: ref}} = state) do
    {:noreply, state |> clear_probe() |> probe_failed({:probe_crashed, reason}) |> clear_released_watchdog()}
  end

  def handle_info({:remote_head, pid, result}, %{probe: %{pid: pid}} = state) do
    {:noreply, state |> clear_probe() |> on_remote_head(result) |> clear_released_watchdog()}
  end

  def handle_info({:probe_timeout, ref}, %{probe: %{ref: ref, pid: pid}} = state) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    {:noreply, state |> clear_probe() |> probe_failed(:timeout) |> clear_released_watchdog()}
  end

  def handle_info({:dispatch_hold_timeout, watchdog_ref}, %{dispatch_watchdog: %{ref: watchdog_ref}} = state) do
    if hold_phase?(state.phase) do
      if hold_progress?(state) do
        # A live worker avoids the idle timeout. Builds also have a separate
        # total deadline that survives this re-arm.
        {:noreply, rearm_dispatch_watchdog(state)}
      else
        # The worker is dead with no completion signal in flight — the absorbing
        # hold from #2237. Abort any residue and release the dispatch gate.
        stalled_phase = state.phase
        reason = {:repo_base_dispatch_hold_stalled, stalled_phase}
        log_and_emit_error(reason)

        {:noreply,
         state
         |> abort_probe()
         |> abort_build()
         |> clear_dispatch_watchdog()
         |> Map.merge(%{phase: {:error, reason}, freshness: :unknown})}
      end
    else
      # The hold ended while this timer was in flight (e.g. a build completed).
      {:noreply, clear_dispatch_watchdog(state)}
    end
  end

  def handle_info({:build_hold_timeout, timeout_ref}, %{build: %{timeout_ref: timeout_ref, deadline: deadline}} = state) do
    case BuildTimeout.remaining(deadline) do
      remaining when remaining > 0 ->
        timer = BuildTimeout.schedule(self(), timeout_ref, deadline)
        {:noreply, %{state | build: %{state.build | timer: timer}}}

      _ ->
        reason = {:repo_base_build_hold_timeout, state.build_hold_timeout_ms}
        log_and_emit_error(reason)

        {:noreply,
         state
         |> abort_build()
         |> clear_dispatch_watchdog()
         |> Map.merge(%{phase: {:error, reason}, freshness: :unknown})}
    end
  end

  def handle_info({:build_hold_timeout, _build_ref}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  ## ---- async orchestration ----

  defp do_refresh_async(state) do
    case Settings.resolve() do
      :disabled ->
        disable_prewarm(state)

      {:ok, repo_url, base, command} ->
        state = %{state | base_path: base}

        cond do
          state.build != nil -> ensure_probe(state, repo_url)
          state.phase == :checking -> ensure_probe(state, repo_url)
          match?({:error, {:repo_base_build_hold_timeout, _}}, state.phase) -> state
          state.phase == :ready -> probe_freshness(state, repo_url)
          true -> start_build(state, base, repo_url, command)
        end
    end
  end

  # Dispatch must not race a ready base against an outstanding `ls-remote`.
  # A confirmed probe grants one dispatch pass; the following pass starts the
  # next probe and holds until it resolves. This keeps a remote advance from
  # creating a workspace off the previous recorded clone head.
  defp do_refresh_for_dispatch(state) do
    case Settings.resolve() do
      :disabled ->
        disable_prewarm(state)

      {:ok, repo_url, base, command} ->
        state
        |> Map.put(:base_path, base)
        |> dispatch_refresh_state(repo_url, base, command)
        |> sync_dispatch_watchdog()
    end
  end

  defp dispatch_refresh_state(state, repo_url, base, command) do
    cond do
      state.build != nil -> ensure_probe(state, repo_url)
      state.phase == :checking -> ensure_probe(state, repo_url)
      match?({:error, _}, state.phase) -> state
      state.phase == :ready and state.freshness == :fresh -> %{state | freshness: :unknown}
      state.phase == :ready -> probe_freshness(state, repo_url)
      true -> start_build(state, base, repo_url, command)
    end
  end

  # the base branch advanced past what the warm checkout reflects -> preempt any in-flight build and
  # rebuild fresh; otherwise stay put.
  defp on_remote_head(state, {:ok, head}) do
    if advanced?(state, head), do: trigger_build(state), else: confirm_freshness(state)
  end

  defp on_remote_head(state, {:error, reason}), do: probe_failed(state, reason)

  defp trigger_build(state) do
    case Settings.resolve() do
      {:ok, repo_url, base, command} -> start_build(state, base, repo_url, command)
      :disabled -> disable_prewarm(state)
    end
  end

  defp start_build(state, base, repo_url, command) do
    kill_build(state)
    timeout_ms = BuildTimeout.timeout_ms(state.build_hold_timeout_ms_override)
    deadline = BuildTimeout.deadline(timeout_ms)
    timeout_ref = make_ref()
    timer = BuildTimeout.schedule(self(), timeout_ref, deadline)
    parent = self()
    {pid, ref} = spawn_monitor(fn -> build_worker(parent, base, repo_url, command) end)

    build = BuildTimeout.build_state(pid, ref, timeout_ref, timer, deadline, timeout_ms)
    %{state | phase: :building, base_path: base, build: build, freshness: :unknown, build_hold_timeout_ms: timeout_ms}
  end

  defp abort_build(%{build: %{}} = state) do
    kill_build(state)
    if is_reference(state.build.timer), do: Process.cancel_timer(state.build.timer)
    %{state | build: nil}
  end

  defp abort_build(state), do: state

  defp disable_prewarm(state) do
    state
    |> abort_probe()
    |> abort_build()
    |> clear_dispatch_watchdog()
    |> Map.merge(%{phase: :idle, freshness: :unknown})
  end

  defp kill_build(%{build: %{pid: pid, ref: ref, timer: timer} = build}) do
    Process.demonitor(ref, [:flush])
    if is_reference(timer), do: Process.cancel_timer(timer)
    BuildProcess.kill_async(%{build | pid: pid})
    :ok
  end

  defp kill_build(_state), do: :ok

  # Runs the refresh in the worker, reporting the locked head before building
  # (so the GenServer can preempt) and the final result when done.
  defp build_worker(server, base, repo_url, command) do
    on_process = fn event, os_pid, group_id, identity ->
      GenServer.call(server, {:build_os_process, self(), event, os_pid, group_id, identity}, :infinity)
    end

    result =
      case Preparer.prepare(base, repo_url, on_process) do
        {:ok, changed?} ->
          head = Clone.head_of(base)
          send(server, {:build_head, self(), head})

          outcome =
            Clone.maybe_build(base, command, changed? or not Clone.built?(base, command), on_process)

          send(server, {:build_done, self(), head, outcome})
          outcome

        {:error, _reason} = err ->
          send(server, {:build_done, self(), nil, err})
          err
      end

    case result do
      {:ok, _} -> emit(:ready)
      {:error, reason} -> log_and_emit_error(reason)
    end
  end

  @doc false
  @spec git_auth_env(String.t() | nil) :: [{String.t(), String.t()}]
  defdelegate git_auth_env(token), to: Clone

  @doc false
  @spec read_ledger(Path.t(), atom(), {module(), atom()} | nil) :: {:ok, String.t()} | {:error, term()}
  defdelegate read_ledger(path, kind, validator), to: Aiur.RepoBase.Ledger

  defp schedule_poll do
    case poll_interval_ms() do
      ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :poll, ms)
      _ -> :ok
    end
  end

  defp poll_interval_ms do
    case Config.settings() do
      {:ok, settings} -> max(settings.prewarm.poll_seconds || 0, 0) * 1000
      _ -> 0
    end
  end

  defp base_root, do: Paths.repo_state_root()
  defp emit(phase), do: AgentPubSub.broadcast_prewarm_phase(phase)

  # Prewarm failures used to be broadcast only as a phase event, so a base that
  # could not build looped silently while agents fell back to cold clones. Log
  # at error (with the captured command output) at the source, then broadcast.
  defp log_and_emit_error(reason) do
    Logger.error("prewarm base unavailable: " <> format_error(reason))
    emit({:error, reason})
  end

  defp format_error({tag, status, out}) when is_integer(status) and is_binary(out),
    do: "#{tag} (exit #{status}): #{String.slice(String.trim(out), 0, 1500)}"

  defp format_error(reason), do: inspect(reason)
end

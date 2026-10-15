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
  alias Aiur.RepoBase.Clone
  alias Aiur.RepoBase.Migration
  alias Aiur.RepoBase.StateTree

  # The probe owns its 30-second timeout, so a *live* probe self-resolves. This
  # watchdog instead bounds *idle* dispatch holds: it re-arms while the hold's
  # worker (probe or build) is alive, and fires only once the worker has been
  # dead for a full interval — releasing the gate for cold-clone fallback. A
  # slow-but-progressing cold build (deps + compile + dialyzer PLT) is never
  # killed by it; only a hold whose completion signal was lost is.
  @dispatch_hold_timeout_ms 600_000

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
    with {:ok, changed?} <- prepare_clone(base_path, repo_url) do
      Clone.maybe_build(base_path, base_build, changed? or not Clone.built?(base_path, base_build))
    end
  end

  # Shared by the sync and worker paths: migrate, create state, clone, fetch.
  defp prepare_clone(base_path, repo_url) do
    with :ok <- Migration.remove_obsolete_aiur_node(slug(repo_url), base_root()),
         :ok <- Migration.migrate_legacy_layout(base_path),
         :ok <- StateTree.ensure_state_tree_at(Path.dirname(base_path)),
         :ok <- Clone.ensure_clone(base_path, repo_url) do
      Clone.fetch_and_reset(base_path)
    end
  end

  ## ---- GenServer ----

  @impl true
  def init(opts) do
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
       dispatch_watchdog: nil
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {state.phase, state.base_path}, state}
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

  def handle_info({:build_done, pid, head, result}, %{build: %{pid: pid, ref: ref}} = state) do
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
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{build: %{ref: ref}} = state) do
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
        # The hold's worker is still alive, so the operation is progressing (a
        # live probe self-resolves via its own 30-second timeout; a live build
        # is a real process that may legitimately run for many minutes). Re-arm
        # the idle watchdog instead of tearing the work down.
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

  def handle_info(_msg, state), do: {:noreply, state}

  ## ---- async orchestration ----

  defp do_refresh_async(state) do
    case resolve() do
      :disabled ->
        disable_prewarm(state)

      {:ok, repo_url, base, command} ->
        state = %{state | base_path: base}

        cond do
          state.build != nil -> ensure_probe(state, repo_url)
          state.phase == :checking -> ensure_probe(state, repo_url)
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
    case resolve() do
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
    case resolve() do
      {:ok, repo_url, base, command} -> start_build(state, base, repo_url, command)
      :disabled -> disable_prewarm(state)
    end
  end

  defp start_build(state, base, repo_url, command) do
    kill_build(state)
    parent = self()

    {pid, ref} = spawn_monitor(fn -> build_worker(parent, base, repo_url, command) end)

    %{state | phase: :building, base_path: base, build: %{pid: pid, ref: ref, head: nil}, freshness: :unknown}
  end

  defp abort_build(%{build: %{}} = state) do
    kill_build(state)
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

  defp kill_build(%{build: %{pid: pid, ref: ref}}) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    :ok
  end

  defp kill_build(_state), do: :ok

  # Runs the refresh in the worker, reporting the locked head before building
  # (so the GenServer can preempt) and the final result when done.
  defp build_worker(server, base, repo_url, command) do
    result =
      case prepare_clone(base, repo_url) do
        {:ok, changed?} ->
          head = Clone.head_of(base)
          send(server, {:build_head, self(), head})
          outcome = Clone.maybe_build(base, command, changed? or not Clone.built?(base, command))
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

  ## ---- config / topology ----

  # Resolves the configured pre-warm target, or `:disabled` when pre-warm is off,
  # has no detected build command, or the tracker is not a github repo (local
  # base path is meaningless without a clone source).
  defp resolve do
    with {:ok, settings} <- Config.settings(),
         %{enabled: true, base_build: command} when is_binary(command) and command != "" <-
           settings.prewarm,
         repo when is_binary(repo) and repo != "" <- Aiur.GitHub.Config.repo() do
      url = "https://github.com/#{repo}.git"
      {:ok, url, base_path(url), command}
    else
      _ -> :disabled
    end
  end

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
  defp slug(repo_url), do: Paths.repo_slug(repo_url)

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

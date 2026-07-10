defmodule Aiur.RepoBase do
  @moduledoc """
  Maintains one warm, pre-compiled base checkout of the target repo's base branch (`tracker.base_branch`, default `main`) at
  `~/.aiur/repo/<owner>/<name>` so per-issue workspaces materialize from it
  (copy-on-write) instead of cold-cloning + recompiling on every dispatch.

  Builds run asynchronously in a spawned worker so the GenServer mailbox stays
  responsive — the orchestrator's eager-dispatch gate reads `status/0` rather
  than blocking on a build. The build command is the repo-agnostic
  `prewarm.base_build` filled by toolchain detection at `aiur init`.
  `_build`/deps are gitignored, so `reset --hard origin/<base>` updates tracked
  source but leaves build artifacts — refreshes are incremental.

  On every base-branch advance the base is rebuilt; a newer advance detected
  mid-build (via `git ls-remote`, which never touches the base working tree)
  PREEMPTS the in-flight build so workspaces never spin off a stale base. Phase
  events (`:cloning` -> `:fetching` -> `:building` -> `:ready` / `{:error, _}`)
  are broadcast for the agent-list loading bar.
  """
  use GenServer
  require Logger

  alias Aiur.AgentEnvironment
  alias Aiur.AgentPubSub
  alias Aiur.Config

  @built_marker ".aiur-base-built"
  @default_branch "main"

  ## ---- Public API ----

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Absolute path of the warm base for `repo_url`."
  @spec base_path(String.t()) :: Path.t()
  def base_path(repo_url) when is_binary(repo_url),
    do: Path.join(base_root(), slug(repo_url))

  @doc """
  Current base status as `{phase, base_path | nil}`. Fast and non-blocking —
  the orchestrator gate and the loading UI read this. `phase` is `:idle`,
  `:cloning`, `:fetching`, `:building`, `:ready`, or `{:error, reason}`.
  """
  @spec status() :: {atom() | {:error, term()}, Path.t() | nil}
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Trigger an asynchronous refresh of the warm base toward the latest remote base branch.
  No-op when pre-warm is disabled / unconfigured. Safe to call every poll cycle:
  rebuilds only when the base branch advanced, and preempts an in-flight build when it
  has. Returns immediately.
  """
  @spec refresh_async() :: :ok
  def refresh_async, do: GenServer.cast(__MODULE__, :refresh_async)

  @doc """
  The branch the warm base tracks: `tracker.base_branch` from config, falling
  back to `"main"` when unset, empty, or the config cannot be loaded.
  """
  @spec base_branch() :: String.t()
  def base_branch do
    case Config.settings() do
      {:ok, %{tracker: %{base_branch: name}}} when is_binary(name) and name != "" -> name
      _ -> @default_branch
    end
  end

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
    with :ok <- ensure_clone(base_path, repo_url),
         {:ok, changed?} <- fetch_and_reset(base_path) do
      maybe_build(base_path, base_build, changed? or not built?(base_path))
    end
  end

  ## ---- GenServer ----

  @impl true
  def init(_opts) do
    schedule_poll()
    {:ok, %{phase: :idle, base_path: nil, build: nil, probe: nil, ready_head: nil}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {state.phase, state.base_path}, state}
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
  # so a later ls-remote probe can tell whether main advanced past it.
  def handle_info({:build_head, pid, head}, %{build: %{pid: pid} = build} = state) do
    {:noreply, %{state | build: %{build | head: head}}}
  end

  def handle_info({:build_head, _pid, _head}, state), do: {:noreply, state}

  def handle_info({:build_done, pid, head, result}, %{build: %{pid: pid, ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | build: nil}

    case result do
      {:ok, base} -> {:noreply, %{state | phase: :ready, base_path: base, ready_head: head}}
      {:error, reason} -> {:noreply, %{state | phase: {:error, reason}}}
    end
  end

  def handle_info({:build_done, _pid, _head, _result}, state), do: {:noreply, state}

  # The build worker crashed without a clean :build_done.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{build: %{ref: ref}} = state) do
    log_and_emit_error({:build_crashed, reason})
    {:noreply, %{state | build: nil, phase: {:error, {:build_crashed, reason}}}}
  end

  def handle_info({:remote_head, head}, state) do
    {:noreply, on_remote_head(%{state | probe: nil}, head)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## ---- async orchestration ----

  defp do_refresh_async(state) do
    case resolve() do
      :disabled ->
        %{state | phase: :idle}

      {:ok, repo_url, base, command} ->
        state = %{state | base_path: base}

        cond do
          state.build != nil -> ensure_probe(state, repo_url)
          state.phase == :ready -> ensure_probe(state, repo_url)
          true -> start_build(state, base, repo_url, command)
        end
    end
  end

  # An ls-remote probe answers "did main advance?" without touching the base
  # working tree, so it is safe to run alongside an in-flight build.
  defp ensure_probe(%{probe: nil} = state, repo_url) do
    parent = self()

    {pid, ref} = spawn_monitor(fn -> send(parent, {:remote_head, remote_head(repo_url)}) end)

    %{state | probe: %{pid: pid, ref: ref}}
  end

  defp ensure_probe(state, _repo_url), do: state

  # main advanced past what the base reflects -> preempt any in-flight build and
  # rebuild fresh; otherwise stay put.
  defp on_remote_head(state, head) do
    if advanced?(state, head), do: trigger_build(state), else: state
  end

  # in-flight build is targeting an older head
  defp advanced?(%{build: %{head: build_head}}, head)
       when is_binary(build_head) and is_binary(head),
       do: head != build_head

  # base is ready but main moved past it
  defp advanced?(%{build: nil, phase: :ready, ready_head: ready_head}, head)
       when is_binary(head),
       do: head != ready_head

  defp advanced?(_state, _head), do: false

  defp trigger_build(state) do
    case resolve() do
      {:ok, repo_url, base, command} -> start_build(state, base, repo_url, command)
      :disabled -> %{state | phase: :idle}
    end
  end

  defp start_build(state, base, repo_url, command) do
    kill_build(state)
    parent = self()

    {pid, ref} = spawn_monitor(fn -> build_worker(parent, base, repo_url, command) end)

    %{state | phase: :building, base_path: base, build: %{pid: pid, ref: ref, head: nil}}
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
      with :ok <- ensure_clone(base, repo_url),
           {:ok, changed?} <- fetch_and_reset(base) do
        head = head_of(base)
        send(server, {:build_head, self(), head})
        outcome = maybe_build(base, command, changed? or not built?(base))
        send(server, {:build_done, self(), head, outcome})
        outcome
      else
        {:error, _reason} = err ->
          send(server, {:build_done, self(), nil, err})
          err
      end

    case result do
      {:ok, _} -> emit(:ready)
      {:error, reason} -> log_and_emit_error(reason)
    end
  end

  ## ---- refresh steps (emit phase events; shared by sync + worker paths) ----

  defp ensure_clone(base_path, repo_url) do
    if File.dir?(Path.join(base_path, ".git")) do
      :ok
    else
      emit(:cloning)
      File.rm_rf!(base_path)
      File.mkdir_p!(Path.dirname(base_path))

      case git(["clone", "--branch", base_branch(), repo_url, base_path], nil) do
        {_out, 0} -> :ok
        {out, status} -> {:error, {:repo_base_clone_failed, status, out}}
      end
    end
  end

  defp fetch_and_reset(base_path) do
    emit(:fetching)
    branch = base_branch()

    with {_fetch, 0} <- git(["fetch", "origin", branch, "--quiet"], base_path),
         {local, 0} <- git(["rev-parse", "HEAD"], base_path),
         {remote, 0} <- git(["rev-parse", "origin/#{branch}"], base_path) do
      reset_if_changed(base_path, String.trim(local) == String.trim(remote))
    else
      {out, status} -> {:error, {:repo_base_fetch_failed, status, out}}
    end
  end

  defp reset_if_changed(_base_path, true), do: {:ok, false}

  defp reset_if_changed(base_path, false) do
    case git(["reset", "--hard", "origin/#{base_branch()}"], base_path) do
      {_out, 0} -> {:ok, true}
      {out, status} -> {:error, {:repo_base_reset_failed, status, out}}
    end
  end

  defp maybe_build(base_path, _base_build, false), do: {:ok, base_path}

  defp maybe_build(base_path, base_build, true) do
    emit(:building)

    case run_base_build(base_path, base_build) do
      :ok ->
        mark_built(base_path)
        {:ok, base_path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_base_build(_base_path, nil), do: :ok
  defp run_base_build(_base_path, ""), do: :ok

  defp run_base_build(base_path, command) do
    # Same execution shape as workspace hooks: scrub the operator's Erlang
    # distribution env at the shell level, then run in the base dir. `base_env/1`
    # trusts the base's mise.toml (MISE_TRUSTED_CONFIG_PATHS) so mise-provided
    # tools run; the detected command still sets its own HEX_HOME/MIX_HOME so the
    # base owns the caches workspaces copy.
    scrubbed = AgentEnvironment.scrub_shell_command(command)

    {out, status} =
      System.cmd("sh", ["-lc", scrubbed],
        cd: base_path,
        env: AgentEnvironment.base_env(base_path),
        stderr_to_stdout: true
      )

    case status do
      0 -> :ok
      _ -> {:error, {:base_build_failed, status, out}}
    end
  end

  ## ---- git / fs helpers ----

  defp git(args, nil), do: System.cmd("git", args, stderr_to_stdout: true, env: git_auth_env())
  defp git(args, cwd), do: System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true, env: git_auth_env())

  # Auth for networked git calls. Git never reads GITHUB_TOKEN on its own, so a
  # warm-base clone/fetch of a private repo 401s ("Password authentication is not
  # supported") — and with no TTY it then hangs/fails trying to prompt for a
  # username. We inject the token as a per-host HTTP Authorization header via
  # git's env-based config (GIT_CONFIG_*), matching what GitHub Actions does:
  #
  #   - env config (not `-c key=value`) keeps the token out of argv / `ps`
  #   - a clean origin URL keeps it out of the cloned `.git/config`
  #   - scoping to `http.https://github.com/.` confines it to github.com
  #
  # `GIT_TERMINAL_PROMPT=0` makes git fail fast instead of blocking on a
  # credential prompt (the "could not read Username … Device not configured"
  # case) when no token is available. The header is HTTP-transport only, so it is
  # inert for the local rev-parse/reset calls that also route through `git/2`.
  defp git_auth_env, do: git_auth_env(Aiur.GitHub.Config.token())

  @doc false
  @spec git_auth_env(String.t() | nil) :: [{String.t(), String.t()}]
  def git_auth_env(token) when is_binary(token) and token != "" do
    header = "AUTHORIZATION: basic " <> Base.encode64("x-access-token:" <> token)

    [
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_CONFIG_COUNT", "1"},
      {"GIT_CONFIG_KEY_0", "http.https://github.com/.extraheader"},
      {"GIT_CONFIG_VALUE_0", header}
    ]
  end

  def git_auth_env(_token), do: [{"GIT_TERMINAL_PROMPT", "0"}]

  defp head_of(base_path) do
    case git(["rev-parse", "HEAD"], base_path) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp remote_head(repo_url) do
    case git(["ls-remote", repo_url, "refs/heads/#{base_branch()}"], nil) do
      {out, 0} -> out |> String.split() |> List.first()
      _ -> nil
    end
  end

  defp built?(base_path), do: File.exists?(Path.join(base_path, @built_marker))
  defp mark_built(base_path), do: File.write!(Path.join(base_path, @built_marker), "")

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

  defp base_root do
    Application.get_env(:aiur, :repo_base_root) || Path.expand("~/.aiur/repo")
  end

  # Reduce a repo URL or local path to a stable `<owner>/<name>`-style slug for
  # the base directory. Handles https/ssh URLs and bare local paths.
  defp slug(repo_url) do
    repo_url
    |> String.trim_trailing("/")
    |> String.replace_suffix(".git", "")
    |> String.split(~r{[/:]})
    |> Enum.reject(&(&1 in ["", "https", "http", "ssh", "git", "github.com"]))
    |> Enum.take(-2)
    |> Enum.join("/")
  end

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

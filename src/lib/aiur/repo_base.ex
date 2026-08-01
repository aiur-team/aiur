defmodule Aiur.RepoBase do
  @moduledoc """
  Maintains one warm, pre-compiled base checkout of the target repo's base branch (`tracker.base_branch`, default `main`) at
  `~/.aiur/repo/<owner>/<name>/latest` so per-issue workspaces materialize from it
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

  @base_record "base-record.json"
  @legacy_built_marker ".aiur-base-built"
  @cache_sidecars [".aiur-hex", ".aiur-mix", ".aiur-npm-cache"]
  @remote_probe_timeout_ms 30_000

  ## ---- Public API ----

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Absolute path of the warm base for `repo_url`."
  @spec base_path(String.t()) :: Path.t()
  def base_path(repo_url) when is_binary(repo_url),
    do: Path.join(repo_path(repo_url), "latest")

  @doc "Absolute path of the per-repository state node for `repo_url`."
  @spec repo_path(String.t()) :: Path.t()
  def repo_path(repo_url) when is_binary(repo_url),
    do: Path.join(base_root(), slug(repo_url))

  @doc "Absolute path of the build-order store for `repo_url`."
  @spec builds_path(String.t()) :: Path.t()
  def builds_path(repo_url) when is_binary(repo_url),
    do: Path.join(repo_path(repo_url), "builds")

  @doc """
  Current base status as `{phase, base_path | nil}`. Fast and non-blocking —
  the orchestrator gate and the loading UI read this. `phase` is `:idle`,
  `:cloning`, `:fetching`, `:building`, `:checking`, `:ready`, or
  `{:error, reason}`.
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

  @doc false
  @spec refresh_for_dispatch() :: atom() | {:error, term()}
  def refresh_for_dispatch, do: GenServer.call(__MODULE__, :refresh_for_dispatch)

  @doc """
  The branch the warm base tracks: `tracker.base_branch` from config, falling
  back to `"main"` when unset, empty, or the config cannot be loaded.
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
    with :ok <- remove_obsolete_aiur_node(repo_url),
         :ok <- migrate_legacy_layout(base_path),
         :ok <- ensure_clone(base_path, repo_url),
         {:ok, changed?} <- fetch_and_reset(base_path) do
      maybe_build(base_path, base_build, changed? or not built?(base_path, base_build))
    end
  end

  ## ---- GenServer ----

  @impl true
  def init(_opts) do
    schedule_poll()
    {:ok, %{phase: :idle, base_path: nil, build: nil, probe: nil, ready_head: nil, freshness: :unknown}}
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
  # so a later ls-remote probe can tell whether main advanced past it.
  def handle_info({:build_head, pid, head}, %{build: %{pid: pid} = build} = state) do
    {:noreply, %{state | build: %{build | head: head}}}
  end

  def handle_info({:build_head, _pid, _head}, state), do: {:noreply, state}

  def handle_info({:build_done, pid, head, result}, %{build: %{pid: pid, ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | build: nil}

    case result do
      {:ok, base} -> {:noreply, %{state | phase: :ready, base_path: base, ready_head: head, freshness: :unknown}}
      {:error, reason} -> {:noreply, %{state | phase: {:error, reason}}}
    end
  end

  def handle_info({:build_done, _pid, _head, _result}, state), do: {:noreply, state}

  # The build worker crashed without a clean :build_done.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{build: %{ref: ref}} = state) do
    log_and_emit_error({:build_crashed, reason})
    {:noreply, %{state | build: nil, phase: {:error, {:build_crashed, reason}}}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{probe: %{ref: ref}} = state) do
    {:noreply, state |> clear_probe() |> probe_failed({:probe_crashed, reason})}
  end

  def handle_info({:remote_head, pid, result}, %{probe: %{pid: pid}} = state) do
    {:noreply, state |> clear_probe() |> on_remote_head(result)}
  end

  def handle_info({:probe_timeout, ref}, %{probe: %{ref: ref, pid: pid}} = state) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    {:noreply, state |> clear_probe() |> probe_failed(:timeout)}
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
          state.phase == :checking -> state
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
        %{state | phase: :idle}

      {:ok, repo_url, base, command} ->
        state
        |> Map.put(:base_path, base)
        |> dispatch_refresh_action(repo_url, base, command)
    end
  end

  defp dispatch_refresh_action(state, repo_url, base, command) do
    cond do
      state.build != nil -> ensure_probe(state, repo_url)
      state.phase == :checking -> state
      match?({:error, _}, state.phase) -> state
      state.phase == :ready and state.freshness == :fresh -> %{state | freshness: :unknown}
      state.phase == :ready -> probe_freshness(state, repo_url)
      true -> start_build(state, base, repo_url, command)
    end
  end

  # An ls-remote probe answers "did main advance?" without touching the base
  # working tree, so it is safe to run alongside an in-flight build.
  defp ensure_probe(%{probe: nil} = state, repo_url) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, {:remote_head, self(), remote_head(repo_url)})
      end)

    timer = Process.send_after(self(), {:probe_timeout, ref}, @remote_probe_timeout_ms)
    %{state | probe: %{pid: pid, ref: ref, timer: timer}}
  end

  defp ensure_probe(state, _repo_url), do: state

  defp probe_freshness(state, repo_url) do
    state
    |> ensure_probe(repo_url)
    |> Map.put(:phase, :checking)
  end

  # main advanced past what the base reflects -> preempt any in-flight build and
  # rebuild fresh; otherwise stay put.
  defp on_remote_head(state, {:ok, head}) do
    if advanced?(state, head), do: trigger_build(state), else: confirm_freshness(state)
  end

  defp on_remote_head(state, {:error, reason}), do: probe_failed(state, reason)

  defp confirm_freshness(%{phase: :checking} = state), do: %{state | phase: :ready, freshness: :fresh}
  defp confirm_freshness(state), do: state

  # A failed probe must never certify a clone as current. Surface the failure so
  # the dispatcher deliberately takes its cold-clone fallback for this tick;
  # later scheduled refreshes can retry the probe/build without handing an
  # unverified warm base to a workspace.
  defp probe_failed(%{build: nil, phase: :checking} = state, reason) do
    %{state | phase: {:error, {:repo_base_remote_probe_failed, reason}}, freshness: :unknown}
  end

  defp probe_failed(state, _reason), do: state

  # in-flight build is targeting an older head
  defp advanced?(%{build: %{head: build_head}}, head)
       when is_binary(build_head) and is_binary(head),
       do: head != build_head

  # base is ready but main moved past it
  defp advanced?(%{build: nil, phase: phase, ready_head: ready_head}, head)
       when phase in [:ready, :checking] and is_binary(head),
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

    %{state | phase: :building, base_path: base, build: %{pid: pid, ref: ref, head: nil}, freshness: :unknown}
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
      with :ok <- remove_obsolete_aiur_node(repo_url),
           :ok <- migrate_legacy_layout(base),
           :ok <- ensure_clone(base, repo_url),
           {:ok, changed?} <- fetch_and_reset(base) do
        head = head_of(base)
        send(server, {:build_head, self(), head})
        outcome = maybe_build(base, command, changed? or not built?(base, command))
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
        with :ok <- relocate_sidecars(base_path),
             :ok <- write_base_record(base_path, base_build) do
          {:ok, base_path}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_base_build(_base_path, nil), do: :ok
  defp run_base_build(_base_path, ""), do: :ok

  defp run_base_build(base_path, command) do
    # Same execution shape as workspace hooks: scrub the Executor’s Erlang
    # distribution env at the shell level, then run in the base dir. `base_env/1`
    # trusts the base's mise.toml (MISE_TRUSTED_CONFIG_PATHS) so mise-provided
    # tools run. Cache homes point at the repository node, outside `latest`, so
    # materialized workspaces inherit only the repository tree.
    scrubbed = AgentEnvironment.scrub_shell_command(command)

    {out, status} =
      System.cmd("sh", ["-lc", scrubbed],
        cd: base_path,
        env: base_env(base_path),
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
      {out, 0} ->
        case out |> String.split() |> List.first() do
          head when is_binary(head) and head != "" -> {:ok, head}
          _ -> {:error, :empty_remote_head}
        end

      {out, status} ->
        {:error, {:ls_remote_failed, status, out}}
    end
  end

  # A boolean marker made a moved clone indistinguishable from a freshly built
  # one. Keep the record beside `latest`, where it cannot leak into a copied
  # workspace, and require both inputs that define a valid build to match.
  defp built?(base_path, base_build) do
    with {:ok, record_body} <- File.read(base_record_path(base_path)),
         {:ok, record} <- Jason.decode(record_body),
         clone_head when is_binary(clone_head) <- Map.get(record, "clone_head"),
         script_hash when is_binary(script_hash) <- Map.get(record, "prewarm_script_hash"),
         true <- clone_head == head_of(base_path),
         true <- script_hash == prewarm_script_hash(base_build) do
      true
    else
      _ -> false
    end
  end

  defp write_base_record(base_path, base_build) do
    with head when is_binary(head) <- head_of(base_path),
         :ok <- File.mkdir_p(repo_node_path(base_path)),
         {:ok, body} <-
           Jason.encode(%{
             "clone_head" => head,
             "prewarm_script_hash" => prewarm_script_hash(base_build),
             "built_at" => DateTime.utc_now() |> DateTime.to_iso8601()
           }) do
      target = base_record_path(base_path)
      temporary = target <> ".tmp-" <> unique_suffix()

      with :ok <- File.write(temporary, body),
           :ok <- File.rename(temporary, target) do
        :ok
      else
        {:error, reason} ->
          File.rm(temporary)
          {:error, {:repo_base_record_write_failed, reason}}
      end
    else
      _ -> {:error, :repo_base_head_unavailable}
    end
  end

  defp prewarm_script_hash(base_build) when is_binary(base_build),
    do: :crypto.hash(:sha256, base_build) |> Base.encode16(case: :lower)

  defp prewarm_script_hash(_base_build), do: :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)

  # The old layout made the repository node itself the clone. Moving a directory
  # beneath itself is impossible, so temporarily rename it beside the node,
  # recreate the node, lift sidecars out, and finally move the clone to latest.
  # The legacy marker is intentionally discarded: no record means one correct
  # rebuild after migration.
  defp migrate_legacy_layout(base_path) do
    node = repo_node_path(base_path)

    with :ok <- recover_interrupted_migration(base_path),
         :ok <- migrate_legacy_node(base_path, node),
         do: :ok
  end

  defp migrate_legacy_node(base_path, node) do
    if File.dir?(Path.join(node, ".git")), do: move_legacy_node(base_path, node), else: :ok
  end

  defp move_legacy_node(base_path, node) do
    temporary = node <> ".migrating-" <> unique_suffix()

    with :ok <- File.rename(node, temporary),
         :ok <- File.mkdir_p(node),
         :ok <- move_sidecars(temporary, node),
         :ok <- remove_legacy_marker(temporary),
         :ok <- File.rename(temporary, base_path) do
      :ok
    else
      {:error, reason} -> {:error, {:repo_base_migration_failed, reason}}
    end
  end

  # If the process dies after parking the old node beside its destination but
  # before renaming it to `latest`, finish that move on the next touch. The
  # sidecars may already have been lifted into `node`; keeping that directory
  # intact makes recovery safe at every point in the migration sequence.
  defp recover_interrupted_migration(base_path) do
    node = repo_node_path(base_path)

    parked =
      node
      |> Kernel.<>(".migrating-*")
      |> Path.wildcard()
      |> Enum.filter(&File.dir?(Path.join(&1, ".git")))

    if File.dir?(Path.join(base_path, ".git")), do: :ok, else: recover_parked_migration(node, base_path, parked)
  end

  defp recover_parked_migration(_node, _base_path, []), do: :ok

  defp recover_parked_migration(node, base_path, [temporary]) do
    with :ok <- File.mkdir_p(node),
         :ok <- move_sidecars(temporary, node),
         :ok <- remove_legacy_marker(temporary),
         :ok <- File.rename(temporary, base_path) do
      :ok
    else
      {:error, reason} -> {:error, {:repo_base_migration_recovery_failed, reason}}
    end
  end

  defp recover_parked_migration(_node, _base_path, _many), do: {:error, :repo_base_migration_recovery_ambiguous}

  defp remove_legacy_marker(path) do
    case File.rm_rf(Path.join(path, @legacy_built_marker)) do
      {:ok, _removed} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  defp relocate_sidecars(base_path), do: move_sidecars(base_path, repo_node_path(base_path))

  # aiur's org transfer left exactly one known predecessor node. It is not a
  # valid state node for the current tracker and can retain the old boolean
  # marker forever, so clear it lazily when the renamed repository is touched.
  defp remove_obsolete_aiur_node(repo_url) do
    if slug(repo_url) == "aiur-team/aiur" do
      case File.rm_rf(Path.join(base_root(), "its-everdred/aiur")) do
        {:ok, _removed} -> :ok
        {:error, reason, _path} -> {:error, {:repo_base_orphan_cleanup_failed, reason}}
      end
    else
      :ok
    end
  end

  defp move_sidecars(from, to) do
    Enum.reduce_while(@cache_sidecars, :ok, fn sidecar, :ok ->
      case move_sidecar(Path.join(from, sidecar), Path.join(to, sidecar)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp move_sidecar(source, target) do
    cond do
      not File.exists?(source) -> :ok
      File.exists?(target) -> discard_sidecar(source)
      true -> File.rename(source, target)
    end
  end

  defp discard_sidecar(source) do
    case File.rm_rf(source) do
      {:ok, _removed} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  defp repo_node_path(base_path), do: Path.dirname(base_path)
  defp base_record_path(base_path), do: Path.join(repo_node_path(base_path), @base_record)

  defp clear_probe(%{probe: %{timer: timer}} = state) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    %{state | probe: nil}
  end

  defp unique_suffix do
    :crypto.strong_rand_bytes(12)
    |> Base.url_encode64(padding: false)
  end

  defp base_env(base_path) do
    node = repo_node_path(base_path)

    AgentEnvironment.base_env(base_path) ++
      [
        {"HEX_HOME", Path.join(node, ".aiur-hex")},
        {"MIX_HOME", Path.join(node, ".aiur-mix")},
        {"npm_config_cache", Path.join(node, ".aiur-npm-cache")}
      ]
  end

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

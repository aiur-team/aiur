defmodule Aiur.TestSupport do
  require Logger

  alias Aiur.Events.Publisher, as: EventsPublisher
  alias Aiur.Events.SubscriptionStore, as: EventsSubscriptionStore
  alias Aiur.GitHub.AuthPreflight, as: GitHubAuthPreflight
  alias Aiur.GitHub.DispatchAuthorization, as: GitHubDispatchAuthorization
  alias Aiur.GitHub.ResourceStore, as: GitHubResourceStore
  alias Aiur.PollCadence

  @workflow_prompt "You are an agent for this repository."
  @github_repository {"its-everdred", "aiur"}

  @doc "The synthetic GitHub repository used by fixture tests."
  @spec github_repository() :: String.t()
  def github_repository, do: Enum.join(Tuple.to_list(@github_repository), "/")

  @doc "The owner component of the synthetic fixture repository."
  @spec github_owner() :: String.t()
  def github_owner, do: elem(@github_repository, 0)

  @doc "The repository-name component of the synthetic fixture repository."
  @spec github_repository_name() :: String.t()
  def github_repository_name, do: elem(@github_repository, 1)

  @doc "Receives a matching message without a wall-clock timeout."
  defmacro receive_barrier(pattern) do
    vars =
      pattern
      |> Macro.prewalk([], fn
        {skip, _, [_]}, acc when skip in [:^, :@, :quote] -> {:ok, acc}
        {skip, _, [_, _]}, acc when skip == :quote -> {:ok, acc}
        {:_, _, context}, acc when is_atom(context) -> {:ok, acc}
        {name, meta, context}, acc when is_atom(name) and is_atom(context) -> {:ok, [{name, meta, context} | acc]}
        node, acc -> {node, acc}
      end)
      |> elem(1)
      |> Enum.uniq_by(fn {name, _meta, context} -> {name, context} end)

    generated_vars = for {name, meta, context} <- vars, do: {name, [generated: true] ++ meta, context}
    match = quote(do: unquote(pattern) = received)

    quote do
      {received, unquote(vars)} =
        receive do
          unquote(match) -> {received, unquote(generated_vars)}
        end

      received
    end
  end

  @doc false
  @spec prepare_workflow_file_path!(Path.t()) :: Path.t()
  def prepare_workflow_file_path!(root) do
    path = Path.join([root, ".aiur", "config"])
    File.mkdir_p!(Path.dirname(path))
    path
  end

  # Application keys the `use Aiur.TestSupport` setup redirects or that its
  # cases replace with process-owned test providers. They must all be put back
  # on the way out so a dead provider cannot leak into the next test module.
  #
  # `:workflow_file_path` is restored rather than deleted: deleting it leaves
  # the global config resolving to a possibly-missing run-folder path, so any
  # later read of `Config.settings!/0` while `WorkflowStore` is
  # mid-reload/restart raises `missing_workflow_file`. That raise in a
  # permanent top-level child's `init/1` (e.g. `Orchestrator`) crash-loops
  # `Aiur.Supervisor` past its `max_restarts` and takes the whole `:aiur` app
  # down — the #589 cascade.
  #
  # `:repo_base_root` is the newest member. `RepoBase` otherwise defaults to
  # `~/.aiur/repo`, one directory shared by the whole VM, and everything it
  # holds — asks, findings, claims, ticket state — is durable. Without a
  # per-test root a case reads records written by a module that ran earlier in
  # the same partition.
  #
  # `:loadavg_source_override` / `:proc_stat_source_override` are the host-CPU
  # equivalent of `:build_gate_dir_override`: without them every dispatch
  # decision a case makes reads the real `/proc/loadavg` and `/proc/stat` of a
  # box that is also running the rest of the fleet, so a routing assertion
  # passes or fails on ambient load rather than on the code under test (#2089).
  # A case that deliberately exercises an admission gate overrides both keys
  # itself; teardown puts the deterministic baseline back.
  @isolated_app_env_keys [
    :workflow_file_path,
    :log_file,
    :build_gate_dir_override,
    :global_pause_store_path,
    :github_cache_inspector_source,
    :github_resource_store_path,
    :github_cache_inspector_source,
    :repo_base_root,
    :executor_state_dir,
    :loadavg_source_override,
    :proc_stat_source_override
  ]

  # A quiet host: no load pressure, and a `/proc/stat` whose counters advance on
  # every read so `SystemCpu.headroom/2` measures a real window (90% idle) for
  # any consecutive pair instead of degrading to `:unavailable`.
  @quiet_loadavg "0.00 0.00 0.00 1/1 1\n"

  @doc false
  @spec quiet_loadavg_source() :: (-> {:ok, String.t()})
  def quiet_loadavg_source, do: fn -> {:ok, @quiet_loadavg} end

  @doc false
  @spec quiet_proc_stat_source() :: (-> {:ok, String.t()})
  def quiet_proc_stat_source do
    fn ->
      tick = System.unique_integer([:monotonic, :positive])
      {:ok, "cpu  #{100 * tick} 0 0 #{900 * tick} 0 0 0 0 0 0\nprocs_running 1\n"}
    end
  end

  @doc "The `:aiur` application keys isolated per TestSupport case."
  @spec isolated_app_env_keys() :: [atom()]
  def isolated_app_env_keys, do: @isolated_app_env_keys

  @doc """
  An absolute path under the system tmp dir that no *other* VM on this host can
  also choose.

  `System.unique_integer/1` is node-scoped: it makes a name unique inside one
  `mix test` VM and gives no protection at all across VMs. Every VM draws from
  the same narrow window of counter values, so two concurrent `mix test` runs on
  one host pick the same `<tmp>/<prefix>_<integer>` name routinely — measured at
  60 shared names across 2 x 320 draws from two simultaneous runs of the same
  file. When that happens the second VM creates its fixture tree inside the
  directory the first VM's teardown is recursively removing, and `File.rm_rf!/1`
  fails on the `rmdir` of a directory it had just emptied: ENOTEMPTY, which
  Erlang reports as `:eexist` and Elixir renders as "file already exists". The
  symptom looks like a writer racing teardown because it *is* one — the writer is
  another VM running the same test.

  `System.pid/0` is what makes the path host-unique; only one VM can own an OS
  pid at a time. `config/config.exs` already isolates the suite-global log root
  the same way. Prefer this over hand-rolling `Path.join(System.tmp_dir!(), ...)`.
  """
  @spec tmp_root!(String.t()) :: Path.t()
  def tmp_root!(prefix) when is_binary(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}")
  end

  @doc "Captures the current value of every isolated key, unset included."
  @spec capture_app_env() :: [{atom(), {:ok, term()} | :error}]
  def capture_app_env do
    Enum.map(@isolated_app_env_keys, &{&1, Application.fetch_env(:aiur, &1)})
  end

  @doc """
  Resets every piece of VM-global state a TestSupport case may have moved.

  All of it lives in `:persistent_term`, so it outlasts the process that wrote
  it and leaks between cases in the same VM. Each case therefore starts from the
  production-safe default:

    * `Aiur.Events.Publisher` / `Aiur.Events.SubscriptionStore` — a filtering or
      enqueue stub would otherwise silently affect an unrelated Exchange case.
    * `Aiur.GitHub.ResourceStore` — it records which GitHub resource each
      published event was, deliberately global and restart-durable so a webhook
      delivery can suppress the poll sweep that re-reads the same comment. In a
      suite that means comment id 1 on issue 42 in one case would suppress
      comment id 1 on issue 42 in the next.
    * `Aiur.GitHub.AuthPreflight` — it remembers the credential it proved, so a
      success recorded by one case would let a later case's poll cycle skip a
      preflight it expects to observe.
    * `Aiur.PollCadence` — every Orchestrator poll cycle writes the effective
      interval there and every freshness threshold in the tree derives from it,
      so a case that drives a poll cycle would move the staleness windows for
      every later case.
    * `Aiur.GitHub.DispatchAuthorization` — it caches the verified applier of
      the trigger label per `{id, label, updated_at}`. One case's timeline
      decision would otherwise be reused by a later case that happens to fetch
      the same issue id with the same labels and `updated_at`, skipping (or
      wrongly satisfying) the timeline fetch that later case expected to drive
      (#2082).
  """
  @spec reset_global_state!() :: :ok
  def reset_global_state! do
    EventsPublisher.set_tracked_fn(fn _ -> true end)
    EventsSubscriptionStore.set_enqueue_fn(nil)
    ensure_resource_store_running()
    GitHubResourceStore.reset()
    GitHubAuthPreflight.invalidate(:test_setup)
    PollCadence.forget_effective_interval_ms()
    GitHubDispatchAuthorization.clear_cache()
    :ok
  end

  @doc "Puts back what `capture_app_env/0` recorded, deleting keys that were unset."
  @spec restore_app_env([{atom(), {:ok, term()} | :error}]) :: :ok
  def restore_app_env(captured) do
    Enum.each(captured, fn
      {key, :error} -> Application.delete_env(:aiur, key)
      {key, {:ok, value}} -> Application.put_env(:aiur, key, value)
    end)
  end

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias Aiur.AgentRunner
      alias Aiur.CLI
      alias Aiur.Codex.CodingAgent, as: AppServer
      alias Aiur.Config
      alias Aiur.HttpServer
      alias Aiur.Issue
      alias Aiur.Linear.Client
      alias Aiur.Orchestrator
      alias Aiur.PromptBuilder
      alias Aiur.StatusDashboard
      alias Aiur.Tracker
      alias Aiur.Workflow
      alias Aiur.WorkflowStore
      alias Aiur.Workspace

      # Backend config aliases for tests
      alias Aiur.Codex.Config, as: CodexConfig
      alias Aiur.Events.Publisher, as: EventsPublisher
      alias Aiur.Events.SubscriptionStore, as: EventsSubscriptionStore
      alias Aiur.GitHub.ResourceStore, as: GitHubResourceStore
      alias Aiur.Linear.Config, as: LinearConfig

      import Aiur.TestSupport,
        only: [
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          write_workflow_file_async!: 1,
          write_workflow_file_async!: 2,
          write_workflow_file_atomic!: 2,
          receive_barrier: 1,
          restore_env: 2,
          stop_default_http_server: 0,
          ensure_workflow_store_running: 0
        ]

      setup do
        workflow_base =
          Path.join(
            System.tmp_dir!(),
            "aiur-elixir-tests-#{System.get_env("USER") || System.get_env("LOGNAME") || "local"}"
          )

        # `System.pid()` is what keeps this root private to *this* VM. Without it
        # two `mix test` runs on one host pick the same `workflow-<integer>` name
        # routinely and then write each other's `.aiur/config`, so a case reads a
        # sibling VM's tracker settings. See `Aiur.TestSupport.tmp_root!/1`.
        workflow_root =
          Path.join(
            workflow_base,
            "workflow-#{System.pid()}-#{System.unique_integer([:positive])}"
          )

        # Every application key this setup overrides, captured as-is so
        # teardown puts back exactly what was there. See
        # `Aiur.TestSupport.isolated_app_env_keys/0`.
        previous_app_env = Aiur.TestSupport.capture_app_env()

        Aiur.TestSupport.reset_global_state!()

        File.mkdir_p!(workflow_root)

        # Pin the host-pressure probes to a quiet host so admission decisions are
        # a function of the test's own state, not of what else is running on the
        # box (#2089).
        Application.put_env(:aiur, :loadavg_source_override, Aiur.TestSupport.quiet_loadavg_source())
        Application.put_env(:aiur, :proc_stat_source_override, Aiur.TestSupport.quiet_proc_stat_source())

        Application.put_env(:aiur, :repo_base_root, Path.join(workflow_root, "repo"))

        # Durable Executor state (journal, wake ledger, cursor, subscriptions,
        # claims) lives at a per-repository path that survives a restart. That
        # is exactly what makes it leak across cases without a per-test root:
        # one case's journal is another's replay input.
        Application.put_env(:aiur, :executor_state_dir, Path.join([workflow_root, "executor-state"]))
        Application.put_env(:aiur, :build_gate_dir_override, Path.join(workflow_root, "build-gate"))
        Application.put_env(:aiur, :global_pause_store_path, Path.join(workflow_root, "global-pause.json"))
        workflow_file = Aiur.TestSupport.prepare_workflow_file_path!(workflow_root)
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)

        # Isolate per-issue/per-repo persistent state (issue logs, the central
        # alert feed, and SessionHandle resume files) under the per-test workflow
        # root. Without this, `Paths.log_root_dir/0` defaults to the shared
        # `<cwd>/log`, where a leftover `<repo>.<id>.session.json` makes a later
        # test's agent runner resume a prior thread (building the "session
        # resumed" continuation prompt) instead of cold-starting — an
        # order-dependent failure that only surfaces when the leaking sibling
        # test is absent from the run (e.g. `mix test test/aiur/core_test.exs`).
        File.mkdir_p!(Path.join(workflow_root, "log"))
        Application.put_env(:aiur, :log_file, Path.join([workflow_root, "log", "aiur.log"]))

        # Global pause is deliberately durable in production, but that makes a
        # suite-wide test path hazardous: a case that pauses the daemon can
        # make a later named Orchestrator boot paused. Give every TestSupport
        # case its own store so persisted control state cannot cross test
        # boundaries or depend on ExUnit's randomized file order.
        Application.put_env(
          :aiur,
          :global_pause_store_path,
          Path.join([workflow_root, "state", "global-pause.json"])
        )

        # A prior test may have terminated the shared WorkflowStore singleton
        # (e.g. extensions_test / core_test tear it down) and, on a mid-test
        # failure, left it down. Bring it back up before this test reads config
        # through it, so a sibling never calls into a torn-down store — the #780
        # `WorkspaceAndConfigTest` flake: `GenServer.call(WorkflowStore, :current)`
        # exiting `:shutdown`. Then reload it onto this test's config path.
        Aiur.TestSupport.ensure_runtime_children_running()
        if Process.whereis(Aiur.WorkflowStore), do: Aiur.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          Aiur.TestSupport.restore_app_env(previous_app_env)
          Application.delete_env(:aiur, :server_port_override)
          Application.delete_env(:aiur, :memory_tracker_issues)
          Application.delete_env(:aiur, :memory_tracker_recipient)
          EventsPublisher.set_tracked_fn(fn _ -> true end)
          EventsSubscriptionStore.set_enqueue_fn(nil)
          File.rm_rf(workflow_root)

          # Reload the store onto the restored baseline so the next test never
          # observes the now-deleted `workflow_root` config, and recover the
          # app if a sibling test's child terminate/restart toppled it while
          # the config was transiently bad (the #589 cascade safety net).
          if Process.whereis(Aiur.WorkflowStore) do
            try do
              Aiur.WorkflowStore.force_reload()
            catch
              :exit, _ -> :ok
            end
          end

          unless Process.whereis(Aiur.Supervisor) do
            Application.ensure_all_started(:aiur)
          end
        end)

        :ok
      end
    end
  end

  @workflow_reload_timeout_ms 15_000

  @doc """
  Writes a workflow fixture and waits for the active `WorkflowStore` cache to
  reload before returning.

  Files other than the active workflow path are staging fixtures and do not
  trigger a reload.
  """
  def write_workflow_file!(path, overrides \\ []) do
    write_workflow_content!(path, overrides)

    if active_workflow_file?(path) do
      ensure_workflow_store_running()
      :ok = Aiur.WorkflowStore.force_reload(@workflow_reload_timeout_ms)
    end

    :ok
  end

  @doc """
  Writes a workflow fixture and makes a best-effort attempt to reload the
  active `WorkflowStore` cache.

  The reload call can block until the store responds or its configured timeout
  elapses. Use this only when the test deliberately exercises asynchronous
  reload behavior: reload failures are logged and swallowed, so callers have
  no cache-visibility guarantee.
  """
  def write_workflow_file_async!(path, overrides \\ []) do
    write_workflow_content!(path, overrides)

    if active_workflow_file?(path) and is_pid(Process.whereis(Aiur.WorkflowStore)) do
      try do
        case Aiur.WorkflowStore.force_reload(async_workflow_reload_timeout_ms()) do
          :ok -> :ok
          {:error, reason} -> log_async_reload_failure(path, reason)
        end
      catch
        :exit, reason -> log_async_reload_failure(path, reason)
      end
    end

    :ok
  end

  @doc """
  Writes raw YAML to a workflow fixture atomically (temp file + rename) and
  does not reload the store.

  Use for intentionally-invalid fixture content, which must land as a single
  unit: a plain `File.write!/2` truncates before writing, so the
  `WorkflowStore` background poll can read the empty intermediate — empty YAML
  parses successfully — and commit those defaults as last-known-good before the
  test's own `force_reload/1` runs (#1635).
  """
  @spec write_workflow_file_atomic!(Path.t(), String.t()) :: :ok
  def write_workflow_file_atomic!(path, content) when is_binary(content) do
    atomic_write!(path, content)
  end

  defp write_workflow_content!(path, overrides) do
    {config_yaml, prompt} = workflow_content(overrides)

    config_yaml =
      if is_binary(prompt) and prompt != "" do
        prompt_basename = String.trim_leading(Path.basename(path), ".") <> ".prompt.md"
        File.write!(Path.join(Path.dirname(path), prompt_basename), prompt <> "\n")
        config_yaml <> "prompt_file: #{prompt_basename}\n"
      else
        config_yaml
      end

    atomic_write!(path, config_yaml)
    write_default_alerts_file!(path)
  end

  # `File.write!/2` truncates before writing, so a `WorkflowStore` poll (or an
  # unrelated restart) can observe an empty intermediate file and commit it as
  # a valid last-known-good workflow (empty YAML parses successfully). Write to
  # a sibling temp file and rename so the active config only ever exists as a
  # complete unit (#1635).
  defp atomic_write!(path, content) do
    tmp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp"
      )

    File.write!(tmp, content)
    File.rename!(tmp, path)
    :ok
  end

  defp active_workflow_file?(path) do
    Path.expand(path) == Path.expand(Aiur.Workflow.workflow_file_path())
  end

  defp async_workflow_reload_timeout_ms do
    Application.get_env(:aiur, :workflow_store_call_timeout_ms, 5_000)
  end

  defp log_async_reload_failure(path, reason) do
    Logger.warning("Best-effort workflow reload failed path=#{path} reason=#{inspect(reason)}; WorkflowStore may serve stale test config")
  end

  # Mirror the real `.aiur/` layout in tests: drop the canonical alert
  # definitions next to the generated config so `Alerts` resolves its default
  # `<config-dir>/alerts` the same way a real run does. Tests that need
  # different (or no) definitions still override via `:alerts_file_path` or an
  # `alerts_file` config entry — both take precedence over this default.
  @default_alerts_source Path.expand("../../../.aiur/alerts", __DIR__)

  @doc "Absolute path of the repository's canonical `.aiur/alerts` definitions, or nil."
  @spec default_alerts_source() :: String.t() | nil
  def default_alerts_source, do: @default_alerts_source

  defp write_default_alerts_file!(config_path) do
    dest = Path.join(Path.dirname(config_path), "alerts")
    if File.regular?(@default_alerts_source), do: File.cp!(@default_alerts_source, dest)
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  @doc """
  Returns a skip reason when `pgrep -P <pid>` cannot read the OS process list,
  or `nil` when it can.

  The process-reaping tests spawn a `bash -lc` wrapper, discover the child it
  forks via `pgrep -P`, then assert the production reap path kills the whole
  tree. Both the discovery and the production reap (`RemoteControl.collect_descendants/1`)
  depend on `pgrep`. In sandboxes where `pgrep` cannot reach the process list —
  e.g. the macOS agent sandbox, which fails with `sysmond service not found` /
  `pgrep: Cannot get process list` — those tests strand at child discovery
  before the code under test even runs. Tests gate on this with
  `@tag skip: @pgrep_skip_reason` so they skip with a clear reason there and
  still run wherever `pgrep` works (Linux CI, the dogfood box, macOS dev).

  The probe is functional, not OS-based: it backgrounds a known child and
  confirms `pgrep -P` actually discovers it (exit 0). A broken `pgrep` errors
  instead of returning the child, which is exactly the failure being guarded.
  """
  @spec pgrep_skip_reason() :: String.t() | nil
  def pgrep_skip_reason do
    if System.find_executable("pgrep") do
      probe =
        ~s(sleep 1 & child=$!; pgrep -P $$ >/dev/null 2>&1; rc=$?; kill "$child" 2>/dev/null; exit $rc)

      case System.cmd("sh", ["-c", probe], stderr_to_stdout: true) do
        {_out, 0} ->
          nil

        _ ->
          "pgrep cannot read the process list in this environment (e.g. macOS sandbox: sysmond unavailable)"
      end
    else
      "pgrep is not on $PATH"
    end
  end

  def stop_default_http_server do
    case Process.whereis(Aiur.Supervisor) do
      supervisor when is_pid(supervisor) ->
        stop_default_http_server(supervisor)

      nil ->
        ensure_aiur_supervisor_running()
    end
  end

  defp stop_default_http_server(supervisor) do
    case stop_default_http_server_child() do
      :ok -> :ok
      :supervisor_unavailable -> recover_stopped_supervisor(supervisor, &ensure_aiur_supervisor_running/0)
    end
  end

  defp stop_default_http_server_child do
    case Enum.find(Supervisor.which_children(Aiur.Supervisor), fn
           {Aiur.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {Aiur.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  catch
    :exit, _reason -> :supervisor_unavailable
  end

  @doc """
  Stops a server during test teardown, tolerating a process that has already
  exited.

  `start_link`ed servers are linked to the test process, so when the test
  finishes its exit propagates over the link and tears the server down. An
  `on_exit/1` callback runs *afterward* in a separate process, so a
  `Process.alive?/1` / `Process.whereis/1` guard around `GenServer.stop/1` is a
  TOCTOU race: the guard observes the server alive, the link teardown then kills
  it, and the stop crashes with `no process`. Under coverage instrumentation the
  teardown window widens and the race trips intermittently. `safe_stop/1`
  catches that `:exit` instead of guarding, so an already-dead process is a
  no-op. Accepts a pid or a registered name.
  """
  @spec safe_stop(GenServer.server()) :: :ok
  def safe_stop(server) do
    GenServer.stop(server)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec await_process_down(pid(), timeout()) :: :ok | :error
  def await_process_down(process, timeout \\ 2_000) when is_pid(process) do
    ref = Process.monitor(process)

    receive do
      {:DOWN, ^ref, :process, ^process, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        :error
    end
  end

  @doc """
  Restores the shared application children that ordinary tests rely on after a
  sibling intentionally stopped one for an unavailable-service case.
  """
  def ensure_runtime_children_running do
    with :ok <- ensure_aiur_supervisor_running(),
         :ok <- ensure_pubsub_running(),
         :ok <- ensure_subscription_store_supervisor_running(),
         :ok <- ensure_branch_ref_store_running(),
         :ok <- ensure_workflow_store_running(),
         :ok <- ensure_read_cache_running() do
      ensure_resource_store_running()
    end
  end

  @doc """
  Ensures the shared `Aiur.Events.BranchRefStore` singleton is running after a
  sibling test tears down or restarts the application supervisor.
  """
  @spec ensure_branch_ref_store_running() :: :ok | :error
  def ensure_branch_ref_store_running do
    ensure_aiur_supervisor_running()

    case Process.whereis(Aiur.Events.BranchRefStore) do
      pid when is_pid(pid) -> :ok
      nil -> restart_branch_ref_store()
    end
  end

  @doc """
  Ensures the shared GitHub resource store is running before a test resets or
  seeds it. A stopped store deliberately makes writes no-ops, so merely calling
  `ResourceStore.reset/0` cannot distinguish an empty store from a missing one.
  """
  @spec ensure_resource_store_running() :: :ok | :error
  def ensure_resource_store_running do
    ensure_aiur_supervisor_running()

    case Process.whereis(GitHubResourceStore) do
      pid when is_pid(pid) -> :ok
      nil -> restart_resource_store()
    end
  end

  @doc """
  Ensures the shared `Aiur.WorkflowStore` singleton is running, restarting the
  supervised child when a prior test terminated it and left it down. Tolerates
  restart races (already-started / already-present / restarting / not-found) by
  re-checking the registered name. Best-effort: returns `:ok` when the store is
  up, `:error` only if it could not be brought back.
  """
  def ensure_workflow_store_running do
    ensure_aiur_supervisor_running()

    case Process.whereis(Aiur.WorkflowStore) do
      pid when is_pid(pid) -> :ok
      nil -> restart_workflow_store()
    end
  end

  @doc """
  Ensures the shared `Aiur.PubSub` registry is running, restarting the
  supervised `Phoenix.PubSub.Supervisor` child when a prior test terminated it
  (or the application supervisor toppled while a sibling was unavailable).
  Tests that subscribe to `Aiur.PubSub` must call this before subscribing —
  the registry is a shared app child that a sibling can stop, and subscribing
  to a missing registry raises `ArgumentError: unknown registry: Aiur.PubSub`
  rather than failing silently (#2397). Prefer this over `start_supervised!`-ing
  a replacement `Phoenix.PubSub` under the ExUnit supervisor: a temporary
  replacement dies at module end and can leave the shared name permanently
  unregistered for every later test in the suite. Signal-based (`Process.whereis`)
  — never a duration.
  """
  @spec ensure_pubsub_running() :: :ok | :error
  def ensure_pubsub_running(retries \\ 1) do
    case Process.whereis(Aiur.PubSub) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case restart_pubsub_child() do
          {:ok, pid} when is_pid(pid) ->
            :ok

          {:error, {:already_started, pid}} when is_pid(pid) ->
            :ok

          :supervisor_unavailable when retries > 0 ->
            ensure_aiur_supervisor_running()
            ensure_pubsub_running(retries - 1)

          _ ->
            pubsub_status()
        end
    end
  end

  @doc """
  Ensures the shared `Aiur.Events.SubscriptionStoreSupervisor` is running
  before a test attaches a per-issue subscription store. A missing dynamic
  supervisor makes `SubscriptionStore.attach/1` exit with `:noproc` (#2397).
  Signal-based (`Process.whereis`) — never a duration.
  """
  @spec ensure_subscription_store_supervisor_running() :: :ok | :error
  def ensure_subscription_store_supervisor_running(retries \\ 1) do
    ensure_aiur_supervisor_running()

    case Process.whereis(Aiur.Events.SubscriptionStoreSupervisor) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case restart_subscription_store_supervisor_child() do
          {:ok, pid} when is_pid(pid) ->
            :ok

          {:error, {:already_started, pid}} when is_pid(pid) ->
            :ok

          :supervisor_unavailable when retries > 0 ->
            ensure_aiur_supervisor_running()
            ensure_subscription_store_supervisor_running(retries - 1)

          _ ->
            subscription_store_supervisor_status()
        end
    end
  end

  @doc """
  Ensures the shared `Aiur.GitHub.ReadCache` is running before a test reads or
  resets it. A stopped cache makes `ReadCache.snapshot/0` answer `available?:
  false` with no entries, which under load reads as a hard cache miss on every
  request (#2397). Signal-based (`Process.whereis`) — never a duration.
  """
  @spec ensure_read_cache_running() :: :ok | :error
  def ensure_read_cache_running(retries \\ 1) do
    ensure_aiur_supervisor_running()

    case Process.whereis(Aiur.GitHub.ReadCache) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case restart_read_cache_child() do
          {:ok, pid} when is_pid(pid) ->
            :ok

          {:error, {:already_started, pid}} when is_pid(pid) ->
            :ok

          :supervisor_unavailable when retries > 0 ->
            ensure_aiur_supervisor_running()
            ensure_read_cache_running(retries - 1)

          _ ->
            read_cache_status()
        end
    end
  end

  defp read_cache_status do
    if Process.whereis(Aiur.GitHub.ReadCache), do: :ok, else: :error
  end

  defp pubsub_status do
    case Process.whereis(Aiur.PubSub) do
      pid when is_pid(pid) -> :ok
      nil -> :error
    end
  end

  defp subscription_store_supervisor_status do
    case Process.whereis(Aiur.Events.SubscriptionStoreSupervisor) do
      pid when is_pid(pid) -> :ok
      nil -> :error
    end
  end

  defp restart_workflow_store(retries \\ 1) do
    case restart_workflow_store_child() do
      {:ok, pid} when is_pid(pid) ->
        :ok

      {:error, {:already_started, pid}} when is_pid(pid) ->
        :ok

      # The application supervisor can terminate after the initial
      # `Process.whereis/1` check and before the synchronous restart call.
      # Bring it back and retry the child once so a suite sibling cannot leak
      # that narrow shutdown race into an unrelated test setup.
      :supervisor_unavailable when retries > 0 ->
        ensure_aiur_supervisor_running()
        restart_workflow_store(retries - 1)

      :supervisor_unavailable ->
        :error

      # A restart can race a sibling (already-present / running / restarting) or
      # genuinely fail — `WorkflowStore.init/1` reads the workflow file and stops
      # with `{:missing_workflow_file, ...}` when a test transiently pointed the
      # config path at a missing file. A single catch-all keeps both cases from
      # raising a CaseClauseError (`restart_orchestrator/0` can `flunk` on the
      # race because `ExUnit.Assertions` isn't imported into this plain module);
      # fall back to the registered name: `:ok` if up, `:error` if still down.
      {:error, _reason} ->
        if Process.whereis(Aiur.WorkflowStore), do: :ok, else: :error
    end
  end

  defp restart_branch_ref_store(retries \\ 1) do
    case restart_branch_ref_store_child() do
      {:ok, pid} when is_pid(pid) ->
        :ok

      {:error, {:already_started, pid}} when is_pid(pid) ->
        :ok

      :supervisor_unavailable when retries > 0 ->
        ensure_aiur_supervisor_running()
        restart_branch_ref_store(retries - 1)

      :supervisor_unavailable ->
        :error

      {:error, _reason} ->
        if Process.whereis(Aiur.Events.BranchRefStore), do: :ok, else: :error
    end
  end

  defp restart_workflow_store_child do
    Supervisor.restart_child(Aiur.Supervisor, Aiur.WorkflowStore)
  catch
    :exit, _reason -> :supervisor_unavailable
  end

  defp restart_branch_ref_store_child do
    Supervisor.restart_child(Aiur.Supervisor, Aiur.Events.BranchRefStore)
  catch
    :exit, _reason -> :supervisor_unavailable
  end

  defp restart_resource_store(retries \\ 1) do
    case restart_resource_store_child() do
      {:ok, pid} when is_pid(pid) ->
        :ok

      {:error, {:already_started, pid}} when is_pid(pid) ->
        :ok

      :supervisor_unavailable when retries > 0 ->
        ensure_aiur_supervisor_running()
        restart_resource_store(retries - 1)

      :supervisor_unavailable ->
        :error

      {:error, _reason} ->
        if Process.whereis(GitHubResourceStore), do: :ok, else: :error
    end
  end

  defp restart_resource_store_child do
    Supervisor.restart_child(Aiur.Supervisor, GitHubResourceStore)
  catch
    :exit, _reason -> :supervisor_unavailable
  end

  defp restart_pubsub_child do
    Supervisor.restart_child(Aiur.Supervisor, Phoenix.PubSub.Supervisor)
  catch
    :exit, _reason -> :supervisor_unavailable
  end

  defp restart_subscription_store_supervisor_child do
    Supervisor.restart_child(Aiur.Supervisor, Aiur.Events.SubscriptionStoreSupervisor)
  catch
    :exit, _reason -> :supervisor_unavailable
  end

  defp restart_read_cache_child do
    Supervisor.restart_child(Aiur.Supervisor, Aiur.GitHub.ReadCache)
  catch
    :exit, _reason -> :supervisor_unavailable
  end

  defp ensure_aiur_supervisor_running do
    case Process.whereis(Aiur.Supervisor) do
      pid when is_pid(pid) ->
        registered_supervisor_status(pid, &restart_aiur_application/0)

      nil ->
        restart_aiur_application()
    end
  end

  defp restart_aiur_application do
    ensure_aiur_application_started(&verify_or_restart_aiur_application/0)
  end

  defp verify_or_restart_aiur_application do
    case Process.whereis(Aiur.Supervisor) do
      supervisor when is_pid(supervisor) ->
        registered_supervisor_status(supervisor, &stop_and_start_aiur_application/0)

      nil ->
        stop_and_start_aiur_application()
    end
  end

  defp registered_supervisor_status(supervisor, recovery) do
    if supervisor_accepting_calls?(supervisor),
      do: :ok,
      else: recover_stopped_supervisor(supervisor, recovery)
  end

  defp recover_stopped_supervisor(supervisor, recovery) do
    with :ok <- await_process_down(supervisor), do: recovery.()
  end

  defp stop_and_start_aiur_application do
    case Application.stop(:aiur) do
      :ok -> start_aiur_application()
      {:error, {:not_started, :aiur}} -> start_aiur_application()
      {:error, _reason} -> :error
    end
  end

  defp start_aiur_application do
    ensure_aiur_application_started(&aiur_supervisor_status/0)
  end

  defp ensure_aiur_application_started(on_started) do
    case Application.ensure_all_started(:aiur) do
      {:ok, _apps} -> on_started.()
      {:error, {:already_started, _app}} -> on_started.()
      {:error, {:aiur, {:already_started, _app}}} -> on_started.()
      {:error, _reason} -> :error
    end
  end

  defp aiur_supervisor_status do
    case Process.whereis(Aiur.Supervisor) do
      supervisor when is_pid(supervisor) -> if(supervisor_accepting_calls?(supervisor), do: :ok, else: :error)
      nil -> :error
    end
  end

  defp supervisor_accepting_calls?(supervisor) do
    Supervisor.which_children(supervisor)
    true
  catch
    :exit, _reason -> false
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_assignee: nil,
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          tracker_repo: nil,
          tracker_label_prefix: nil,
          tracker_bot_account: nil,
          tracker_github_app_account: nil,
          tracker_trusted_accounts: [],
          tracker_planning_root_limit: 100,
          tracker_planning_page_budget: 4,
          tracker_planning_call_budget: 4,
          tracker_base_branch: "main",
          max_vertical_panes: 3,
          pre_warmed_sessions: 3,
          agent_kind: "codex",
          agent_routing: %{},
          poll_interval_seconds: 30,
          workspace_root: Path.join(System.tmp_dir!(), "aiur_workspaces"),
          workspace_bootstrap_image: nil,
          workspace_bootstrap_image_pull: false,
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_concurrent_builds: 4,
          build_start_stagger_seconds: 0,
          min_free_memory_mb: nil,
          max_turns: 20,
          max_dispatches_per_ticket: nil,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          command: "codex app-server",
          codex_approval_policy: "untrusted",
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          agent_turn_timeout_ms: 3_600_000,
          agent_read_timeout_ms: 5_000,
          agent_stall_timeout_ms: 300_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          opencode_command: "opencode",
          opencode_bridge_port: 4097,
          opencode_bridge_host: "127.0.0.1",
          opencode_serve_args: [],
          opencode_model_prefix: "aiur",
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    tracker_base_branch = Keyword.get(config, :tracker_base_branch)
    tracker_terminal_fence_grace_seconds = Keyword.get(config, :tracker_terminal_fence_grace_seconds)
    agent_kind = Keyword.get(config, :agent_kind)
    agent_routing = Keyword.get(config, :agent_routing)
    max_vertical_panes = Keyword.get(config, :max_vertical_panes)
    pre_warmed_sessions = Keyword.get(config, :pre_warmed_sessions)
    poll_interval_seconds = Keyword.get(config, :poll_interval_seconds)
    workspace_root = Keyword.get(config, :workspace_root)
    workspace_bootstrap_image = Keyword.get(config, :workspace_bootstrap_image)
    workspace_bootstrap_image_pull = Keyword.get(config, :workspace_bootstrap_image_pull)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)

    worker_max_concurrent_agents_per_host =
      Keyword.get(config, :worker_max_concurrent_agents_per_host)

    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_concurrent_builds = Keyword.get(config, :max_concurrent_builds)
    build_start_stagger_seconds = Keyword.get(config, :build_start_stagger_seconds)
    min_free_memory_mb = Keyword.get(config, :min_free_memory_mb)
    max_turns = Keyword.get(config, :max_turns)
    max_dispatches_per_ticket = Keyword.get(config, :max_dispatches_per_ticket)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    agent_turn_timeout_ms = Keyword.get(config, :agent_turn_timeout_ms)
    agent_read_timeout_ms = Keyword.get(config, :agent_read_timeout_ms)
    agent_stall_timeout_ms = Keyword.get(config, :agent_stall_timeout_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_writable = Keyword.get(config, :observability_writable)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    observability_retention_max_bytes = Keyword.get(config, :observability_retention_max_bytes)
    observability_retention_max_age_days = Keyword.get(config, :observability_retention_max_age_days)
    observability_retention_prune_interval_bytes = Keyword.get(config, :observability_retention_prune_interval_bytes)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    opencode_command = Keyword.get(config, :opencode_command)
    opencode_bridge_port = Keyword.get(config, :opencode_bridge_port)
    opencode_bridge_host = Keyword.get(config, :opencode_bridge_host)
    opencode_serve_args = Keyword.get(config, :opencode_serve_args)
    opencode_model_prefix = Keyword.get(config, :opencode_model_prefix)
    prompt = Keyword.get(config, :prompt)

    config =
      if Keyword.has_key?(config, :codex_command) and not Keyword.has_key?(overrides, :command) do
        Keyword.put(config, :command, Keyword.get(config, :codex_command))
      else
        config
      end

    config =
      config
      |> maybe_copy_override(overrides, :codex_turn_timeout_ms, :agent_turn_timeout_ms)
      |> maybe_copy_override(overrides, :codex_read_timeout_ms, :agent_read_timeout_ms)
      |> maybe_copy_override(overrides, :codex_stall_timeout_ms, :agent_stall_timeout_ms)

    _ = {agent_turn_timeout_ms, agent_read_timeout_ms, agent_stall_timeout_ms}

    tracker_section =
      [
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "  base_branch: #{yaml_value(tracker_base_branch)}",
        tracker_terminal_fence_grace_seconds &&
          "  terminal_fence_grace_seconds: #{yaml_value(tracker_terminal_fence_grace_seconds)}",
        tracker_github_yaml(tracker_kind, config),
        tracker_linear_yaml(tracker_kind, config)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    agent_section =
      [
        "agent:",
        "  kind: #{yaml_value(agent_kind)}",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_concurrent_builds: #{yaml_value(max_concurrent_builds)}",
        "  build_start_stagger_seconds: #{yaml_value(build_start_stagger_seconds)}",
        "  min_free_memory_mb: #{yaml_value(min_free_memory_mb)}",
        "  max_turns: #{yaml_value(max_turns)}",
        max_dispatches_per_ticket &&
          "  max_dispatches_per_ticket: #{yaml_value(max_dispatches_per_ticket)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "  routing: #{yaml_value(agent_routing)}",
        "  turn_timeout_ms: #{yaml_value(Keyword.get(config, :agent_turn_timeout_ms))}",
        "  stall_timeout_ms: #{yaml_value(Keyword.get(config, :agent_stall_timeout_ms))}",
        agent_backend_yaml(agent_kind, config)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    sections =
      [
        "max_vertical_panes: #{yaml_value(max_vertical_panes)}",
        "pre_warmed_sessions: #{yaml_value(pre_warmed_sessions)}",
        tracker_section,
        "polling:",
        "  interval_seconds: #{yaml_value(poll_interval_seconds)}",
        polling_intervals_yaml(config),
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        workspace_bootstrap_image && "  bootstrap_image: #{yaml_value(workspace_bootstrap_image)}",
        "  bootstrap_image_pull: #{yaml_value(workspace_bootstrap_image_pull)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        agent_section,
        hooks_yaml(
          hook_after_create,
          hook_before_run,
          hook_after_run,
          hook_before_remove,
          hook_timeout_ms
        ),
        observability_yaml(
          observability_enabled,
          observability_writable,
          observability_refresh_ms,
          observability_render_interval_ms,
          observability_retention_max_bytes,
          observability_retention_max_age_days,
          observability_retention_prune_interval_bytes
        ),
        decisions_yaml(overrides),
        server_yaml(server_port, server_host),
        opencode_yaml(
          opencode_command,
          opencode_bridge_port,
          opencode_bridge_host,
          opencode_serve_args,
          opencode_model_prefix
        ),
        alerts_yaml(overrides),
        pr_watch_yaml(overrides)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    {Enum.join(sections, "\n") <> "\n", prompt}
  end

  defp tracker_linear_yaml("linear", config) do
    endpoint = Keyword.get(config, :tracker_endpoint)
    api_token = Keyword.get(config, :tracker_api_token)
    project_slug = Keyword.get(config, :tracker_project_slug)
    assignee = Keyword.get(config, :tracker_assignee)

    [
      "  linear:",
      "    endpoint: #{yaml_value(endpoint)}",
      "    api_key: #{yaml_value(api_token)}",
      "    project_slug: #{yaml_value(project_slug)}",
      "    assignee: #{yaml_value(assignee)}"
    ]
    |> Enum.join("\n")
  end

  defp tracker_linear_yaml(_kind, _config), do: nil

  defp tracker_github_yaml(tracker_kind, config) do
    repo = if tracker_kind == "github", do: Keyword.get(config, :tracker_repo)
    label_prefix = if tracker_kind == "github", do: Keyword.get(config, :tracker_label_prefix)
    bot_account = if tracker_kind == "github", do: Keyword.get(config, :tracker_bot_account)
    trusted_accounts = if tracker_kind == "github", do: Keyword.get(config, :tracker_trusted_accounts, []), else: []
    root_limit = Keyword.fetch!(config, :tracker_planning_root_limit)
    page_budget = Keyword.fetch!(config, :tracker_planning_page_budget)
    call_budget = Keyword.fetch!(config, :tracker_planning_call_budget)

    [
      "  github:",
      repo && "    repo: #{yaml_value(repo)}",
      label_prefix && "    label_prefix: #{yaml_value(label_prefix)}",
      bot_account && "    bot_account: #{yaml_value(bot_account)}",
      tracker_github_app_yaml(tracker_kind, config),
      trusted_accounts != [] && "    trusted_accounts: #{yaml_value(trusted_accounts)}",
      "    planning_root_limit: #{yaml_value(root_limit)}",
      "    planning_page_budget: #{yaml_value(page_budget)}",
      "    planning_call_budget: #{yaml_value(call_budget)}"
    ]
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.join("\n")
  end

  # Rendered only when a case asks for it, so the default fixture exercises the
  # optional-block path an install without a GitHub App is on.
  defp tracker_github_app_yaml("github", config) do
    case Keyword.get(config, :tracker_github_app_account) do
      nil -> nil
      account -> "    github_app:\n      account: #{yaml_value(account)}"
    end
  end

  defp tracker_github_app_yaml(_kind, _config), do: nil

  defp opencode_yaml(command, bridge_port, bridge_host, serve_args, model_prefix) do
    [
      "opencode:",
      "  command: #{yaml_value(command)}",
      "  bridge_port: #{yaml_value(bridge_port)}",
      "  bridge_host: #{yaml_value(bridge_host)}",
      "  serve_args: #{yaml_value(serve_args)}",
      "  model_prefix: #{yaml_value(model_prefix)}"
    ]
    |> Enum.join("\n")
  end

  defp agent_backend_yaml("codex", config) do
    command = Keyword.get(config, :command)
    approval_policy = Keyword.get(config, :codex_approval_policy)
    thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    read_timeout_ms = Keyword.get(config, :agent_read_timeout_ms)

    [
      "  codex:",
      "    command: #{yaml_value(command)}",
      "    approval_policy: #{yaml_value(approval_policy)}",
      "    thread_sandbox: #{yaml_value(thread_sandbox)}",
      "    turn_sandbox_policy: #{yaml_value(turn_sandbox_policy)}",
      "    read_timeout_ms: #{yaml_value(read_timeout_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp agent_backend_yaml("claude", config) do
    command = Keyword.get(config, :command)
    model = Keyword.get(config, :claude_model)
    permission_mode = Keyword.get(config, :claude_permission_mode)

    [
      "  claude:",
      "    command: #{yaml_value(command)}",
      model && "    model: #{yaml_value(model)}",
      permission_mode && "    permission_mode: #{yaml_value(permission_mode)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp agent_backend_yaml(nil, _config), do: nil
  defp agent_backend_yaml(_kind, _config), do: nil

  # Only renders an `alerts:` block when a test passes alerts overrides, so the
  # default generated config has no alerts section (exercising schema defaults).
  defp alerts_yaml(overrides) do
    lines =
      [
        alerts_line("enabled", overrides, :alerts_enabled),
        alerts_line("use_os_default_sounds", overrides, :alerts_use_os_default_sounds),
        alerts_line("sound_dir", overrides, :alerts_sound_dir),
        alerts_line("alerts_file", overrides, :alerts_file)
      ]
      |> Enum.reject(&is_nil/1)

    if lines == [], do: nil, else: Enum.join(["alerts:" | lines], "\n")
  end

  defp alerts_line(key, overrides, override_key) do
    if Keyword.has_key?(overrides, override_key) do
      "  #{key}: #{yaml_value(Keyword.get(overrides, override_key))}"
    end
  end

  # Only renders a `pr_watch:` block when a test passes pr_watch overrides, so
  # the default generated config exercises the schema defaults (feature off).
  defp pr_watch_yaml(overrides) do
    lines =
      [
        pr_watch_line("enabled", overrides, :pr_watch_enabled),
        pr_watch_line("watch_label", overrides, :pr_watch_watch_label),
        pr_watch_line("command_prefix", overrides, :pr_watch_command_prefix)
      ]
      |> Enum.reject(&is_nil/1)

    if lines == [], do: nil, else: Enum.join(["pr_watch:" | lines], "\n")
  end

  defp pr_watch_line(key, overrides, override_key) do
    if Keyword.has_key?(overrides, override_key) do
      "  #{key}: #{yaml_value(Keyword.get(overrides, override_key))}"
    end
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp maybe_copy_override(config, overrides, from_key, to_key) do
    if Keyword.has_key?(overrides, from_key) and not Keyword.has_key?(overrides, to_key) do
      Keyword.put(config, to_key, Keyword.get(overrides, from_key))
    else
      config
    end
  end

  # Emits `polling.intervals` (per-class cadences, #2309) when the caller passed
  # a `:polling_intervals` map, e.g. %{"planning" => 600, "review" => 300}.
  defp polling_intervals_yaml(config) do
    case Keyword.get(config, :polling_intervals) do
      nil ->
        nil

      intervals when is_map(intervals) and map_size(intervals) > 0 ->
        lines =
          intervals
          |> Enum.sort_by(fn {class, _seconds} -> to_string(class) end)
          |> Enum.map_join("\n", fn {class, seconds} -> "    #{class}: #{yaml_value(seconds)}" end)

        "  intervals:\n" <> lines

      _other ->
        nil
    end
  end

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms),
    do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(
         hook_after_create,
         hook_before_run,
         hook_after_run,
         hook_before_remove,
         timeout_ms
       ) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, writable, refresh_ms, render_interval_ms, retention_max_bytes, retention_max_age_days, retention_prune_interval_bytes) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      writable != nil && "  dashboard_writable: #{yaml_value(writable)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}",
      retention_max_bytes != nil && "  telemetry_retention_max_bytes: #{yaml_value(retention_max_bytes)}",
      retention_max_age_days != nil && "  telemetry_retention_max_age_days: #{yaml_value(retention_max_age_days)}",
      retention_prune_interval_bytes != nil &&
        "  telemetry_retention_prune_interval_bytes: #{yaml_value(retention_prune_interval_bytes)}"
    ]
    |> Enum.reject(&(&1 == false))
    |> Enum.join("\n")
  end

  defp decisions_yaml(overrides) do
    lines =
      [
        decisions_line(
          "supervisor_allowed_kinds",
          overrides,
          :supervisor_decision_allowed_kinds
        ),
        decisions_line(
          "supervisor_allow_non_reversible",
          overrides,
          :supervisor_decision_allow_non_reversible
        )
      ]
      |> Enum.reject(&is_nil/1)

    if lines == [], do: nil, else: Enum.join(["decisions:" | lines], "\n")
  end

  defp decisions_line(key, overrides, override_key) do
    if Keyword.has_key?(overrides, override_key) do
      "  #{key}: #{yaml_value(Keyword.get(overrides, override_key))}"
    end
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end

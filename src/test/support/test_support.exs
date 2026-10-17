defmodule Aiur.TestSupport do
  alias Aiur.Events.Publisher, as: EventsPublisher
  alias Aiur.Events.SubscriptionStore, as: EventsSubscriptionStore
  alias Aiur.GitHub.AuthPreflight, as: GitHubAuthPreflight
  alias Aiur.GitHub.DispatchAuthorization, as: GitHubDispatchAuthorization
  alias Aiur.GitHub.ResourceStore, as: GitHubResourceStore
  alias Aiur.PollCadence

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
  # Host probes use fixtures so dispatch never depends on the fleet's /proc samples (#2089).
  @isolated_app_env_keys [
    :workflow_file_path,
    :log_file,
    :decision_state_dir,
    :build_gate_dir_override,
    :global_pause_store_path,
    :github_resource_store_path,
    :repo_base_root,
    :executor_state_dir,
    :runtime_state_dir,
    :executor_claims_lock_timeout_ms,
    :loadavg_source_override,
    :cpu_pressure_source_override,
    :proc_stat_source_override,
    :workflow_store_config_reader
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

  @doc """
  Points the durable runtime state directory (`Aiur.Config.Paths.runtime_state_dir/0`)
  at `dir` for the calling test and puts the previous value back on exit.

  Tests that isolate `:log_file` to a private directory and then read the alert
  ledger from that directory with `log_roots: [dir]` call this with the same
  directory: the ledger is durable runtime state (#2722), so it follows this
  key, not `:log_file`.
  """
  @spec put_runtime_state_dir!(Path.t()) :: :ok
  def put_runtime_state_dir!(dir) when is_binary(dir) do
    previous = Application.get_env(:aiur, :runtime_state_dir)
    Application.put_env(:aiur, :runtime_state_dir, dir)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :runtime_state_dir, previous),
        else: Application.delete_env(:aiur, :runtime_state_dir)
    end)

    :ok
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

  @doc false
  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      use Aiur.TestScopeGuard
      import ExUnit.CaptureLog

      alias Aiur.{AgentRunner, CLI, Config, HttpServer, Issue, PromptBuilder, StatusDashboard, Tracker, Workflow, WorkflowStore, Workspace}
      alias Aiur.Codex.CodingAgent, as: AppServer
      alias Aiur.Linear.Client
      alias Aiur.Orchestrator

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
          await_orchestrator_state: 2,
          restore_env: 2,
          stop_default_http_server: 0,
          ensure_workflow_store_running: 0
        ]

      setup do
        workflow_base = Application.fetch_env!(:aiur, :test_run_root)
        previous_test_scope_state = Aiur.TestScopeGuard.capture()

        # `System.pid()` is what keeps this root private to *this* VM. Without it
        # two `mix test` runs on one host pick the same `workflow-<integer>` name
        # routinely and then write each other's `.aiur/config`, so a case reads a
        # sibling VM's tracker settings. See `Aiur.TestSupport.tmp_root!/1`.
        workflow_root =
          Path.join(
            workflow_base,
            "workflow-#{System.pid()}-#{System.unique_integer([:positive])}"
          )

        test_state_dir = Path.join(workflow_root, "test-state")

        # Every application key this setup overrides, captured as-is so
        # teardown puts back exactly what was there. See
        # `Aiur.TestSupport.isolated_app_env_keys/0`.
        previous_app_env = Aiur.TestSupport.capture_app_env()

        File.mkdir_p!(workflow_root)
        System.put_env("AIUR_DEV_TEST_STATE_DIR", test_state_dir)

        expected_test_scope_state = %{
          previous_test_scope_state
          | env: Map.put(previous_test_scope_state.env, "AIUR_DEV_TEST_STATE_DIR", test_state_dir)
        }

        # Pin the host-pressure probes to a quiet host so admission decisions are
        # a function of the test's own state, not of what else is running on the
        # box (#2089).
        Application.put_env(:aiur, :loadavg_source_override, Aiur.TestSupport.quiet_loadavg_source())
        Application.put_env(:aiur, :cpu_pressure_source_override, fn -> {:error, :enoent} end)
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
        # test is absent from the run (e.g. `mix test test/aiur/core/`).
        File.mkdir_p!(Path.join(workflow_root, "log"))
        Application.put_env(:aiur, :log_file, Path.join([workflow_root, "log", "aiur.log"]))

        # Subscriptions, session handles and the alert ledger are durable
        # runtime state that survives a restart (#2722); the same leak applies,
        # so each case gets its own runtime state root.
        Application.put_env(:aiur, :runtime_state_dir, Path.join(workflow_root, "runtime-state"))

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
        Aiur.TestSupport.ensure_orchestrator_running()

        Aiur.TestSupport.quiesce_live_orchestrator()
        Aiur.TestSupport.reset_global_state!()
        stop_default_http_server()

        on_exit(fn ->
          scope_state_violation = Aiur.TestScopeGuard.violation(expected_test_scope_state)

          Aiur.TestSupport.quiesce_live_orchestrator()
          Aiur.TestSupport.restore_app_env(previous_app_env)
          Application.delete_env(:aiur, :server_port_override)
          Application.delete_env(:aiur, :memory_tracker_issues)
          Application.delete_env(:aiur, :memory_tracker_recipient)
          EventsPublisher.set_tracked_fn(fn _ -> true end)
          EventsSubscriptionStore.set_enqueue_fn(nil)
          Aiur.TestCleanup.rm_rf!(workflow_root)
          Aiur.TestScopeGuard.restore(previous_test_scope_state)

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

          if scope_state_violation, do: raise(scope_state_violation)
        end)

        :ok
      end
    end
  end

  defdelegate await_orchestrator_state(pid, predicate), to: Aiur.TestSupport.Processes
  defdelegate restore_env(key, value), to: Aiur.TestSupport.Processes
  defdelegate pgrep_skip_reason(), to: Aiur.TestSupport.Processes
  defdelegate stop_default_http_server(), to: Aiur.TestSupport.Processes
  defdelegate safe_stop(server), to: Aiur.TestSupport.Processes
  defdelegate start_owned_endpoint!(), to: Aiur.TestSupport.Processes
  defdelegate await_process_down(process, timeout \\ 2_000), to: Aiur.TestSupport.Processes
  defdelegate await_supervised_restart(name, prior, timeout \\ 5_000), to: Aiur.TestSupport.Processes
  defdelegate ensure_runtime_children_running(), to: Aiur.TestSupport.RuntimeChildren
  defdelegate ensure_orchestrator_running(), to: Aiur.TestSupport.RuntimeChildren
  defdelegate ensure_branch_ref_store_running(), to: Aiur.TestSupport.RuntimeChildren
  defdelegate ensure_resource_store_running(), to: Aiur.TestSupport.RuntimeChildren
  defdelegate ensure_workflow_store_running(), to: Aiur.TestSupport.RuntimeChildren
  defdelegate ensure_pubsub_running(retries \\ 1), to: Aiur.TestSupport.RuntimeChildren
  defdelegate ensure_id_generator_running(), to: Aiur.TestSupport.RuntimeChildren
  defdelegate ensure_provider_meter_store_running(), to: Aiur.TestSupport.RuntimeChildren
  defdelegate ensure_subscription_store_supervisor_running(retries \\ 1), to: Aiur.TestSupport.RuntimeChildren
  defdelegate ensure_read_cache_running(retries \\ 1), to: Aiur.TestSupport.RuntimeChildren

  @doc false
  @spec quiesce_live_orchestrator() :: :ok
  def quiesce_live_orchestrator do
    case freeze_live_orchestrator() do
      pid when is_pid(pid) -> Aiur.TestSupport.await_orchestrator_state(pid, &(map_size(&1.tracker_tasks) == 0))
      _not_running -> :ok
    end

    :ok
  end

  @spec freeze_live_orchestrator() :: pid() | :ok
  def freeze_live_orchestrator do
    case Process.whereis(Aiur.Orchestrator) do
      pid when is_pid(pid) ->
        :sys.replace_state(pid, fn state ->
          if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

          %{
            state
            | tick_timer_ref: nil,
              tick_token: make_ref(),
              next_poll_due_at_ms: nil,
              poll_check_in_progress: false,
              poll_frozen: true
          }
        end)

      nil ->
        :ok
    end
  end

  defdelegate write_workflow_file!(path, overrides \\ []), to: Aiur.TestSupport.WorkflowFiles
  defdelegate write_workflow_file_async!(path, overrides \\ []), to: Aiur.TestSupport.WorkflowFiles
  defdelegate write_workflow_file_atomic!(path, content), to: Aiur.TestSupport.WorkflowFiles
  defdelegate default_alerts_source(), to: Aiur.TestSupport.WorkflowFiles
end

defmodule Aiur.DispatcherTestSupport do
  @moduledoc false
  # Shared setup, doubles and fixture builders for test/aiur/orchestrator/dispatcher/.

  import Aiur.TestSupport, only: [receive_barrier: 1]
  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Aiur.AgentRunner.{SessionLifecycle, ToolExecutor}
  alias Aiur.GitHub.CiReadiness
  alias Aiur.Issue
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, State, TrackerTasks}

  defmacro __using__(_opts) do
    quote do
      use Aiur.TestSupport

      import Aiur.DispatcherTestSupport

      alias Aiur.AgentPubSub
      alias Aiur.AgentRunner.{SessionLifecycle, ToolExecutor}
      alias Aiur.CodexProber
      alias Aiur.DispatcherTestSupport.{CandidateFetchFailureLinearClient, SlowPollOrchestrator}
      alias Aiur.Events.{Exchange, Publisher}
      alias Aiur.GitHub.CiReadiness
      alias Aiur.ModelAvailability
      alias Aiur.Orchestrator.{CapacityBinding, Dispatcher, DispatchPolicy, IssueSync, Slots, State, StatusReport, TrackerHealth, TrackerTasks}
      alias Aiur.RunTelemetry.Lifecycle, as: TelemetryLifecycle

      setup {Aiur.DispatcherTestSupport, :reset_dispatch_env}
    end
  end

  def apply_test_dispatch_result(pending, nil), do: pending

  def apply_test_dispatch_result(pending, _owner) do
    receive_barrier({ref, result})
    {:handled, applied} = TrackerTasks.result(pending, ref, result)
    applied
  end

  defmodule CandidateFetchFailureLinearClient do
    @moduledoc false
    def fetch_candidate_issues, do: {:error, :candidate_fetch_failed}
  end

  # A stand-in Orchestrator whose poll outlasts a delivery call into it. It
  # handles the spawn's redelivery message as `Aiur.Orchestrator` does.
  defmodule SlowPollOrchestrator do
    @moduledoc false
    use GenServer

    alias Aiur.Orchestrator.Dispatcher

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:poll, poll_fun, poll_ms}, _from, test_pid) do
      result = poll_fun.()
      Process.sleep(poll_ms)
      {:reply, result, test_pid}
    end

    def handle_call({:enqueue_answer, decision_id}, _from, test_pid) do
      send(test_pid, {:worker_received, decision_id})
      {:reply, {:ok, %{status: :accepted, item: %{id: System.unique_integer([:positive])}}}, test_pid}
    end

    @impl true
    def handle_info({:deliver_pending_answers, _identifier, _store} = message, test_pid) do
      :ok = Dispatcher.handle_pending_answer_delivery(message)
      {:noreply, test_pid}
    end

    # The spawned runner's `:DOWN` and other Orchestrator traffic.
    def handle_info(_message, test_pid), do: {:noreply, test_pid}
  end

  def wait_until(fun, attempts \\ 200)

  def wait_until(_fun, 0), do: flunk("condition was not reached")

  def wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  @doc false
  def reset_dispatch_env(_context) do
    CiReadiness.clear_cached_result()
    previous_meminfo = Application.get_env(:aiur, :meminfo_source_override)
    previous_loadavg = Application.get_env(:aiur, :loadavg_source_override)
    previous_fd_sample = Application.get_env(:aiur, :file_descriptor_sample_override)
    previous_proc_stat = Application.get_env(:aiur, :proc_stat_source_override)
    previous_build_status = Application.get_env(:aiur, :build_gate_status_override)
    previous_lifecycle_recorder = Application.get_env(:aiur, :run_telemetry_lifecycle_recorder)
    previous_ci_readiness_check_fun = Application.get_env(:aiur, :ci_readiness_check_fun)

    # Dispatch must not shell out to the real build-gate lock files on every
    # poll; default to a free (fail-open) gate status and override per-test.
    Application.put_env(:aiur, :build_gate_status_override, fn ->
      %{enabled?: false, capacity: 0, active: 0, queued: 0}
    end)

    on_exit(fn ->
      restore_app_env(:meminfo_source_override, previous_meminfo)
      restore_app_env(:loadavg_source_override, previous_loadavg)
      restore_app_env(:file_descriptor_sample_override, previous_fd_sample)
      restore_app_env(:proc_stat_source_override, previous_proc_stat)
      Application.delete_env(:aiur, :background_cpu_source_override)
      restore_app_env(:build_gate_status_override, previous_build_status)
      restore_app_env(:run_telemetry_lifecycle_recorder, previous_lifecycle_recorder)
      restore_app_env(:ci_readiness_check_fun, previous_ci_readiness_check_fun)
      CiReadiness.clear_cached_result()
    end)

    :ok
  end

  # Tests that overwrite the shared workflow config must put it back: `Config`
  # re-reads the file on every call, so an unrestored write silently becomes the
  # next test's configuration and raises the odds of the shared WorkflowStore
  # singleton race a reload lands in (#2076 review).
  def restore_workflow_file_after_test do
    path = Aiur.Workflow.workflow_file_path()
    original = File.read!(path)
    on_exit(fn -> File.write!(path, original) end)
  end

  def dispatch_recovery(codex_thrash_budget) do
    %{
      workspace_ownership: %{waits: %{}, ready: %{}},
      codex_thrash_budget: codex_thrash_budget
    }
  end

  def thrash_budget(state), do: state.dispatch_recovery.codex_thrash_budget

  def restore_app_env(key, nil), do: Application.delete_env(:aiur, key)

  def restore_app_env(key, value), do: Application.put_env(:aiur, key, value)

  # Points the workflow config at a prewarm-enabled file for the duration of a
  # test. No `base_build` and a memory tracker keep RepoBase's own resolve/poll
  # inert while `Config.prewarm_enabled?/0` reads true.
  def with_prewarm_enabled_config do
    tmp = Aiur.TestSupport.tmp_root!("dispatcher_prewarm")
    File.mkdir_p!(tmp)
    cfg = Path.join(tmp, "config")
    File.write!(cfg, "tracker:\n  kind: memory\nprewarm:\n  enabled: true\n  poll_seconds: 0\n")

    # Mirror the real `.aiur/` layout: drop the canonical alert definitions next
    # to the generated config so `Alerts` resolves its default `<config-dir>/alerts`
    # the way a real run does. Without it, `Alerts.emit_system/2` still publishes
    # to the exchange but returns `{:error, :missing_message}` — and the alert
    # latches that depend on a `:ok` return (e.g. `prewarm_blocked_alert_active`)
    # never engage.
    alerts_src = Aiur.TestSupport.default_alerts_source()

    if alerts_src && File.regular?(alerts_src) do
      File.cp!(alerts_src, Path.join(tmp, "alerts"))
    end

    previous = Application.get_env(:aiur, :workflow_file_path)
    Aiur.Workflow.set_workflow_file_path(cfg)

    on_exit(fn ->
      case previous do
        nil -> Aiur.Workflow.clear_workflow_file_path()
        path -> Aiur.Workflow.set_workflow_file_path(path)
      end
    end)

    :ok
  end

  def consume_available_slots(state, issues) do
    Enum.reduce(issues, state, fn issue, acc ->
      if DispatchPolicy.should_dispatch_issue?(issue, acc) do
        %{acc | running: Map.put(acc.running, issue.id, running_entry(issue.id))}
      else
        acc
      end
    end)
  end

  def issue(id), do: %Issue{id: id, identifier: "repo##{id}", title: id, state: "todo"}

  # A load hold is only recorded when CPU corroborates it, and the corroboration
  # is a delta between two `/proc/stat` snapshots. Seeding the previous snapshot
  # explicitly — rather than relying on the one the prior tick happened to
  # remember — keeps each window's reclaimable percentage a property of the
  # test rather than of internal bookkeeping. `total: 1_000, idle: 500` against
  # `total: 1_100, idle: 545` is 45% reclaimable, under the 60% clear bar.
  def contended_state(previous_cpu, state \\ %State{max_concurrent_agents: 8, effective_concurrent_agents: 8}) do
    put_in(state.load_envelope_state, %{last_decrease_ms: nil, cpu_snapshot: previous_cpu, bootstrap_complete?: true})
  end

  # `load_threshold` is per scheduler, so 1.5 x 16 is the 24.0 an operator reads
  # on the status line.
  def contended_probes(load, cpu_snapshot) do
    fn ->
      %{
        memory_mb: :unavailable,
        memory_threshold_mb: nil,
        fd_sample: :unavailable,
        runnable: :unavailable,
        run_queue_threshold: nil,
        schedulers: 16,
        load: load,
        load_threshold: 1.5,
        build_status: %{enabled?: false, capacity: 0, active: 0, queued: 0},
        provider_backends: [],
        github_quota: :available,
        cpu_snapshot: cpu_snapshot,
        target: nil
      }
    end
  end

  def dispatch_decision!(issue) do
    test_pid = self()

    runner = fn dispatched_issue, recipient, opts ->
      send(test_pid, {:agent_runner_run, dispatched_issue, recipient, opts})
      :ok
    end

    next_state =
      Dispatcher.do_dispatch_issue(
        %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
        issue,
        nil,
        nil,
        runner: runner
      )

    assert_receive {:agent_runner_run, ^issue, _recipient, runner_opts}, 1000
    attempt_id = Keyword.fetch!(runner_opts, :telemetry_attempt_id)
    assert get_in(next_state.running, [issue.id, :telemetry_attempt_id]) == attempt_id

    {_session_backend, _remote_control?, session_opts} =
      SessionLifecycle.resolve_session_options(issue, runner_opts, nil)

    assert {:ok, session} =
             SessionLifecycle.start_agent_session(
               "/ws",
               session_opts,
               fn _workspace, _opts -> {:ok, %{model: "gpt-5.6-terra", thread_id: "thread-dispatch"}} end
             )

    executor = ToolExecutor.build(issue, nil, nil, session)

    assert executor.("emit_event", %{
             "name" => "decision.requested",
             "message" => "Keep the dispatch attempt?",
             "payload" => %{"blocking" => true}
           })["success"] == true

    [decision] = Aiur.DecisionStore.list() |> Enum.filter(&(&1.ticket.identifier == issue.id))
    {attempt_id, decision}
  end

  def running_entry(id) do
    %{issue: issue(id), control: %{status: :working}, worker_host: nil}
  end

  def dependency_paused_entry(blocker_identifier) do
    %{
      control: %{status: :paused},
      paused_reason: :blocker_dependency,
      blocker_pause: %{blocker_identifier: blocker_identifier}
    }
  end
end

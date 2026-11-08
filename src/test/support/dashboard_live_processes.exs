defmodule AiurWeb.DashboardLiveSupport.Processes do
  @moduledoc false

  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias Aiur.{DecisionDispatch, DecisionMetrics, Issue, RecentMergeStore}
  alias Aiur.Orchestrator.SnapshotStore
  alias AiurWeb.DashboardLiveSupport.OrchestratorStubs.{CountingOrchestrator, QueueOrchestrator}

  def start_counting_orchestrator(name, opts \\ []) do
    start_supervised!(
      {CountingOrchestrator,
       name: name,
       report: Keyword.get(opts, :report),
       block_queued_demand?: Keyword.get(opts, :block_queued_demand?, false),
       snapshot: %{
         running: [],
         retrying: [],
         idle: [],
         agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}
    )
  end

  def replace_counting_snapshot(orchestrator, snapshot) do
    :sys.replace_state(orchestrator, &Map.put(&1, :snapshot, snapshot))
    {:registered_name, name} = Process.info(orchestrator, :registered_name)
    :ok = SnapshotStore.publish(name, snapshot)
  end

  def start_queue_orchestrator(name, identifier, tracker_identity \\ nil) do
    parent = self()
    worker_pid = spawn(fn -> worker_probe(parent) end)
    issue_id = "issue-#{identifier}"

    state = %Aiur.Orchestrator.State{
      poll_interval_ms: 5_000,
      max_concurrent_agents: 1,
      effective_concurrent_agents: 1,
      poll_check_in_progress: false,
      running: %{issue_id => running_entry(issue_id, identifier, worker_pid, tracker_identity)},
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    start_supervised!({QueueOrchestrator, name: name, state: state})

    on_exit(fn ->
      send(worker_pid, :stop)
    end)

    name
  end

  def running_entry(issue_id, identifier, worker_pid, tracker_identity) do
    %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{
        id: issue_id,
        identifier: identifier,
        state: "in-progress",
        title: "OCC integration",
        tracker_identity: tracker_identity
      },
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :working},
      session_id: "thread-#{identifier}",
      codex_app_server_pid: nil,
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      last_codex_timestamp: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }
  end

  def worker_probe(parent) do
    receive do
      :stop ->
        :ok

      message ->
        send(parent, message)
        worker_probe(parent)
    end
  end

  def dispatch_via(orchestrator, dispatcher_opts \\ []) do
    fn decision, opts ->
      opts = Keyword.merge(opts, dispatcher_opts)
      DecisionDispatch.dispatch(decision, Keyword.put(opts, :operator_messages, orchestrator))
    end
  end

  def start_dashboard_metrics(name, decision_store, opts \\ []) do
    dir = Aiur.TestSupport.tmp_root!("aiur-dashboard-metrics")
    path = Path.join(dir, "decision-latency.ndjson")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    metrics_opts =
      Keyword.merge(
        [name: name, path: path, subscribe?: true, seed?: false, decision_store: decision_store],
        opts
      )

    start_supervised!({DecisionMetrics, metrics_opts})
  end

  def start_restartable_dashboard_metrics(name, decision_store) do
    dir = Aiur.TestSupport.tmp_root!("aiur-dashboard-metrics-restart")
    File.mkdir_p!(dir)

    restart = fn ->
      path = Path.join(dir, "decision-latency-#{System.unique_integer([:positive])}.ndjson")

      {:ok, metrics} =
        DecisionMetrics.start_link(
          name: name,
          path: path,
          subscribe?: false,
          seed?: false,
          decision_store: decision_store
        )

      metrics
    end

    metrics = restart.()

    on_exit(fn ->
      stop_registered_metrics(name)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    {metrics, restart}
  end

  # This helper exists for tests that deliberately replace the same-name
  # DecisionMetrics process, so the pid resolved by whereis/1 can already be
  # terminating by the time stop/1 runs. The desired end state — no process
  # registered under this name — is what the teardown wants, so an exit here is
  # success, not a failure of the test that already passed its assertions.
  def stop_registered_metrics(name) do
    case GenServer.whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  catch
    :exit, _reason -> :ok
  end

  def start_recent_merge_store(name) do
    dir = Aiur.TestSupport.tmp_root!("aiur-dashboard-merges")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    start_supervised!({RecentMergeStore, name: name, state_dir: dir, filesystem_sync_fun: fn -> :ok end})
  end
end

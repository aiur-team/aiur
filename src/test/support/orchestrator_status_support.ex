defmodule Aiur.OrchestratorStatusSupport do
  @moduledoc false
  # Fixtures and waiters shared by the `test/aiur/orchestrator/status/` suites.

  import Aiur.TestSupport, only: [receive_barrier: 1, write_workflow_file!: 2]
  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Aiur.AgentQueueStore
  alias Aiur.Codex.CodingAgent, as: CodexCodingAgent
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.State
  alias Aiur.TicketActivity
  alias Aiur.TicketActivity.Projection
  alias Aiur.TicketObservation
  alias Aiur.TrackerIdentity
  alias Aiur.Workflow

  def normalize(event), do: CodexCodingAgent.normalize_event(event)

  def restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  def restore_application_env(key, value), do: Application.put_env(:aiur, key, value)

  def running_entry(issue_id, identifier, status, pid \\ self(), worker_host \\ nil, title \\ nil) do
    %{
      pid: pid,
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{
        id: issue_id,
        identifier: identifier,
        state: "In Progress",
        title: title,
        tracker_identity: tracker_identity(identifier)
      },
      worker_host: worker_host,
      control: %{
        can_interrupt: true,
        safe_checkpoints: [:notification],
        status: status,
        application_confirmation: :confirmed,
        generation: 1,
        version: 0
      },
      codex_app_server_pid: nil,
      codex_process_group_id: nil,
      session_id: "thread-#{identifier}",
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      last_codex_timestamp: nil,
      last_codex_message: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }
  end

  # Starts an orchestrator whose only fleet member is one running issue, so a
  # snapshot assertion is about that issue's progress and nothing else.
  def orchestrator_running_only(issue_id, identifier, identity) do
    orchestrator_name = Module.concat(__MODULE__, :"ProgressOrchestrator#{identifier}")
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    entry =
      issue_id
      |> running_entry(identifier, :working)
      |> put_in([:issue, Access.key(:tracker_identity)], identity)

    :sys.replace_state(pid, fn state -> %{state | running: %{issue_id => entry}} end)

    pid
  end

  def activity_projection(identity, percent, opts \\ []) do
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())

    observation = %TicketObservation{
      status: :joinable,
      reason: nil,
      tracker_identity: identity,
      source: %{kind: :agent_event, name: "progress"},
      event_id: 1,
      provenance: %{run_id: "run-progress", attempt: 1},
      occurred_at: observed_at,
      observed_at: observed_at,
      attributes: %{percent: percent}
    }

    {:accepted, projection} =
      opts
      |> Keyword.take([:stale_after_ms])
      |> Projection.new()
      |> Projection.apply(observation)

    projection
  end

  # The projection validates incoming observations as integers, so a float
  # reading can only be planted directly. It still has to survive the join.
  def put_progress_percent(projection, percent) do
    update_in(projection.entries, fn entries ->
      Map.new(entries, fn {key, entry} -> {key, %{entry | progress: %{entry.progress | percent: percent}}} end)
    end)
  end

  def install_activity_projection(projection) do
    original_state = :sys.get_state(TicketActivity)

    on_exit(fn -> :sys.replace_state(TicketActivity, fn _state -> original_state end) end)

    :sys.replace_state(TicketActivity, fn state -> %{state | projection: projection} end)
  end

  def tracker_identity(identifier) do
    identity_identifier =
      case Regex.run(~r/\d+$/, identifier) do
        [number] -> number
        nil -> "1"
      end

    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "I_kwDO#{identifier}",
      identifier: identity_identifier,
      reason: nil
    }
  end

  def wait_for_status(orchestrator_name, predicate, timeout_ms \\ 5_000)
      when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_status(orchestrator_name, predicate, deadline_ms)
  end

  defp do_wait_for_status(orchestrator_name, predicate, deadline_ms) do
    status = Orchestrator.status(orchestrator_name, 5_000)

    if is_list(status) and predicate.(status) do
      status
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("timed out waiting for orchestrator status: #{inspect(status)}")
      else
        Process.sleep(5)
        do_wait_for_status(orchestrator_name, predicate, deadline_ms)
      end
    end
  end

  def wait_for_snapshot(pid, predicate, timeout_ms \\ 200) when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_snapshot(pid, predicate, deadline_ms)
  end

  defp do_wait_for_snapshot(pid, predicate, deadline_ms) do
    snapshot = GenServer.call(pid, :snapshot)

    if predicate.(snapshot) do
      snapshot
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("timed out waiting for orchestrator snapshot state: #{inspect(snapshot)}")
      else
        Process.sleep(5)
        do_wait_for_snapshot(pid, predicate, deadline_ms)
      end
    end
  end

  # Polls the SnapshotStore read model until the periodic SnapshotPublisher has
  # projected a snapshot matching `predicate`, returning the full read result.
  def wait_for_published_snapshot(orchestrator_name, predicate, timeout_ms \\ 5_000)
      when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_published_snapshot(orchestrator_name, predicate, deadline_ms)
  end

  defp do_wait_for_published_snapshot(orchestrator_name, predicate, deadline_ms) do
    result = Orchestrator.dashboard_snapshot(orchestrator_name, 1_000)

    case result do
      {:current, snapshot, _freshness} ->
        if predicate.(snapshot) do
          result
        else
          retry_published_snapshot(orchestrator_name, predicate, deadline_ms)
        end

      _not_yet_published ->
        retry_published_snapshot(orchestrator_name, predicate, deadline_ms)
    end
  end

  defp retry_published_snapshot(orchestrator_name, predicate, deadline_ms) do
    if System.monotonic_time(:millisecond) >= deadline_ms do
      flunk("timed out waiting for the publisher to project a fleet snapshot for #{inspect(orchestrator_name)}")
    else
      Process.sleep(25)
      do_wait_for_published_snapshot(orchestrator_name, predicate, deadline_ms)
    end
  end

  def operator_message_probe(parent) do
    receive do
      message ->
        send(parent, message)
        operator_message_probe(parent)
    end
  end

  def supervised_operator_message_probe(parent) do
    Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> operator_message_probe(parent) end)
  end

  def freeze_poll_cycle(pid) do
    :sys.replace_state(pid, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

      %{
        state
        | tick_timer_ref: nil,
          tick_token: make_ref(),
          next_poll_due_at_ms: nil,
          poll_check_in_progress: false,
          # The initial tick schedules a one-shot `:run_poll_cycle` (20ms render
          # delay) that is not token-fenced, so it can fire a live poll after
          # this freeze and ramp the load envelope mid-test. Fence it here.
          poll_frozen: true
      }
    end)
  end

  def completed_rework_issue(suffix) do
    %Issue{
      id: "completed-#{suffix}",
      identifier: "MT-COMPLETED-#{String.upcase(suffix)}",
      state: "rework",
      title: "Completed #{suffix}",
      selected_backend: "claude"
    }
  end

  def completed_retention_fixture(issue, worker_host \\ nil) do
    {:ok, worker} = supervised_operator_message_probe(self())
    worker_ref = Process.monitor(worker)

    on_exit(fn ->
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    entry =
      issue.id
      |> running_entry(issue.identifier, :completed, worker, worker_host)
      |> Map.put(:ref, worker_ref)
      |> Map.put(:issue, issue)
      |> Map.put(:session_id, "preserved-#{issue.id}")

    {queue_store, first} =
      AgentQueueStore.enqueue(%AgentQueueStore{}, %{
        target_issue_identifier: issue.identifier,
        source: :operator,
        category: :operator_message,
        event_type: :operator_message,
        body: %{text: "first"}
      })

    {queue_store, second} =
      AgentQueueStore.enqueue(queue_store, %{
        target_issue_identifier: issue.identifier,
        source: :operator,
        category: :operator_message,
        event_type: :operator_message,
        body: %{text: "second"}
      })

    state = %State{
      running: %{issue.id => entry},
      claimed: MapSet.new([issue.id]),
      queue_store: queue_store,
      max_concurrent_agents: 3
    }

    {state, entry, worker, [first.id, second.id]}
  end

  def tracker_completed_retention_fixture(issue, worker_host \\ nil) do
    {state, _entry, worker, item_ids} = completed_retention_fixture(issue, worker_host)
    parked_issue = %{issue | state: "ci-wait"}
    parked = CiLifecycle.pause_issue_for_ci_wait(state, parked_issue)
    parked_entry = Map.fetch!(parked.running, issue.id)

    refute Process.alive?(worker)
    assert parked_entry.control.status == :deactivated
    assert parked_entry.completed_provenance
    assert parked_entry.completion_totals_recorded
    assert parked_entry.pid == nil
    assert parked_entry.ref == nil

    {parked, parked_entry, worker, item_ids}
  end

  def assert_tracker_completed_preflight_retained(state, parked_entry, worker, item_ids) do
    issue = parked_entry.issue
    retained = Map.fetch!(state.running, issue.id)

    refute Process.alive?(worker)
    assert retained.pid == nil
    assert retained.ref == nil
    assert retained.control.status == :completed
    assert retained.completed_provenance
    assert retained.completion_totals_recorded
    assert retained.session_id == parked_entry.session_id
    assert retained.worker_host == parked_entry.worker_host
    assert MapSet.member?(state.claimed, issue.id)
    assert state.queue_store.pending_ids_by_target[issue.identifier] == item_ids
    refute Map.has_key?(state.retry_attempts, issue.id)
    refute Map.has_key?(state.ci_lifecycle.rewakes, issue.id)
  end

  def configure_completed_revalidation!(issues, overrides \\ []) do
    previous_issues = Application.get_env(:aiur, :memory_tracker_issues)

    release_file = Aiur.TestSupport.tmp_root!("completed-revalidation") <> ".release"

    File.rm(release_file)

    config =
      Keyword.merge(
        [
          tracker_kind: "memory",
          tracker_active_states: ["in-progress", "rework"],
          tracker_terminal_states: ["done", "cancelled", "canceled"],
          hook_before_run: "while [ ! -f #{release_file} ]; do sleep 0.01; done"
        ],
        overrides
      )

    write_workflow_file!(Workflow.workflow_file_path(), config)

    Application.put_env(:aiur, :memory_tracker_issues, issues)

    on_exit(fn ->
      File.touch(release_file)
      restore_application_env(:memory_tracker_issues, previous_issues)
    end)

    release_file
  end

  def await_polled_blocker_state(server, issue_id, expected_state) do
    receive_barrier({:poll_state_changed, _payload})
    state = :sys.get_state(server)
    issue = Map.get(state.last_polled_issues, issue_id)

    if issue && Enum.any?(issue.blocked_by, &(&1.state == expected_state)) do
      state
    else
      await_polled_blocker_state(server, issue_id, expected_state)
    end
  end

  def eventually?(fun, attempts \\ 100)

  def eventually?(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually?(fun, attempts - 1)
    end
  end

  def eventually?(_fun, 0), do: false
end

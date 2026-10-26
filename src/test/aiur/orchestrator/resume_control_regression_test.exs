defmodule Aiur.Orchestrator.ResumeControlRegressionTest do
  # Shared application Orchestrator fixture for idle-decision and crash regressions.
  use Aiur.TestSupport
  import ExUnit.CaptureIO
  alias Aiur.{AgentControlCLI, Issue}
  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator.{ControlLifecycle, PauseResume}
  alias Aiur.TrackerIdentity
  import Aiur.SnapshotFenceSupport, only: [fence_snapshot_read_model: 0]
  import Aiur.TrackerTaskDrainSupport, only: [drain_tracker_tasks: 3, drain_tracker_tasks: 4]
  @probe_timeout_ms 15_000

  setup %{test: test_name} do
    pid = Process.whereis(Orchestrator)
    original_state = :sys.get_state(pid, @probe_timeout_ms)

    # Control queries read the SnapshotStore read model first, keyed by the
    # shared registered name, so a projection an earlier module published would
    # hide the running entries these cases inject. A new generation fences
    # in-flight projections, and the Orchestrator adopts it (as in #2719).
    snapshot_generation = fence_snapshot_read_model()

    # Poll reads run in tracker tasks. A poll an earlier case started can still
    # be held by that case's slow tracker double; its late result would apply in
    # the owner during this case and stall the control budget. Freeze
    # polling and cancel in-flight tracker work before each case.
    :sys.replace_state(pid, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)
      %{state | poll_frozen: true, tick_timer_ref: nil, tick_token: make_ref(), next_poll_due_at_ms: nil}
    end)

    drain_tracker_tasks(pid, 15_000, to_string(test_name), original_state.tracker_tasks)

    :sys.replace_state(pid, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

      %{
        state
        | snapshot_generation: snapshot_generation,
          running: %{},
          last_polled_issues: %{},
          retry_attempts: %{},
          claimed: MapSet.new(),
          blocked_ticket_ids: nil,
          control_lifecycle: %ControlLifecycle{},
          tick_timer_ref: nil,
          tick_token: make_ref(),
          next_poll_due_at_ms: nil,
          poll_check_in_progress: false,
          poll_frozen: true,
          candidate_snapshot_fresh?: true,
          snapshot_ready?: false,
          globally_paused: false,
          dispatch_recovery: %{state.dispatch_recovery | workspace_ownership: %{waits: %{}, ready: %{}}}
      }
    end)

    on_exit(fn ->
      if Process.alive?(pid) do
        snapshot_generation = fence_snapshot_read_model()
        drain_tracker_tasks(pid, 15_000, to_string(test_name))
        :sys.replace_state(pid, fn _state -> %{original_state | snapshot_generation: snapshot_generation, tracker_tasks: %{}} end)
      end
    end)

    {:ok, orchestrator: pid}
  end

  defp use_memory_tracker!(issues) do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", max_concurrent_agents: 4)
    previous = Application.get_env(:aiur, :memory_tracker_issues)
    Application.put_env(:aiur, :memory_tracker_issues, issues)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:aiur, :memory_tracker_issues),
        else: Application.put_env(:aiur, :memory_tracker_issues, previous)
    end)
  end

  defp idle_issue(id) do
    %Issue{id: id, identifier: id, title: "Issue #{id}", state: "In Progress", labels: ["agent:in-progress"]}
  end

  defp working_entry(issue_id, identifier, pid) do
    %{
      pid: pid,
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{
        id: issue_id,
        identifier: identifier,
        state: "In Progress",
        title: "Issue #{identifier}",
        tracker_identity: %TrackerIdentity{
          version: 1,
          status: :joinable,
          kind: :github,
          owner: "owner",
          repository: "repo",
          provider_id: "I_kwDO#{issue_id}",
          identifier: identifier,
          reason: nil
        }
      },
      control: %{
        can_interrupt: true,
        safe_checkpoints: [:notification],
        status: :working,
        generation: 1,
        version: 1,
        application_confirmation: :confirmed
      },
      session_id: "thread-#{identifier}",
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      started_at: DateTime.utc_now()
    }
  end

  test "returns a named refusal and keeps the orchestrator and registry", %{orchestrator: pid} do
    use_memory_tracker!([idle_issue("52")])
    bystander = spawn_link(fn -> Process.sleep(:infinity) end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{"53" => working_entry("53", "53", bystander)},
          last_polled_issues: %{"52" => idle_issue("52")},
          blocked_ticket_ids: MapSet.new(["52"])
      }
    end)

    assert {:error, {:blocked_on_decision, %{decision_ids: ids, store: store}}} =
             PauseResume.resume_agent(pid, "52")

    assert is_list(ids)
    assert store in [:available, :unavailable]
    assert Process.whereis(Orchestrator) == pid
    assert %{"53" => %{pid: ^bystander}} = :sys.get_state(pid).running
  end

  test "CLI prints a readable refusal naming decision hold", %{orchestrator: pid} do
    use_memory_tracker!([idle_issue("52")])

    :sys.replace_state(pid, fn state ->
      %{state | last_polled_issues: %{"52" => idle_issue("52")}, blocked_ticket_ids: :unavailable}
    end)

    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.resume(["52"]) end)
        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "failed to resume #52"
    assert stderr =~ "open blocking decision"
    refute stderr =~ "function_clause"
    assert Process.whereis(Orchestrator) == pid
  end

  test "control call crash replies with error and keeps the registry", %{orchestrator: pid} do
    bystander = spawn_link(fn -> Process.sleep(:infinity) end)
    corrupt = "44" |> working_entry("44", self()) |> Map.put(:control, "corrupt")

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"44" => corrupt, "53" => working_entry("53", "53", bystander)}}
    end)

    :ok = Exchange.subscribe("ticket.44.agent.attention.control-call-crashed")

    log =
      capture_log(fn ->
        assert {:error, {:control_call_crashed, :resume, summary}} =
                 PauseResume.resume_agent(pid, "44")

        assert summary =~ "no function clause matching"
        assert {:error, {:control_call_crashed, :pause, _}} = PauseResume.pause_agent(pid, "44")
      end)

    assert log =~ "kept its agent registry"
    assert_receive {:event, %{topic: "ticket.44.agent.attention.control-call-crashed"}}, 2_000
    assert Process.whereis(Orchestrator) == pid
    assert %{"53" => %{pid: ^bystander}, "44" => _} = :sys.get_state(pid).running
  end
end

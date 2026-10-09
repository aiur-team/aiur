defmodule Aiur.Orchestrator.TicketTransitionTest do
  use Aiur.TestSupport
  import ExUnit.CaptureLog
  alias Aiur.{Issue, Tracker, Workflow}
  alias Aiur.Orchestrator.{PauseResume, ReworkRequeue, TicketTransition}

  defmodule ControlServer do
    use GenServer
    def init(state), do: {:ok, state}
    def handle_call({:reset_dispatch_budget, id}, _from, state), do: {:reply, {:tracker_io, {:reset_budget, id, :fetched}, :fetch_issue_states_by_ids, [[id]]}, state}
    def handle_call({:tracker_control_result, :reset_budget, _id, :fetched, result}, _from, state), do: {:reply, result, state}
  end

  defmodule Client do
    def update_issue_state(id, state, opts) do
      send(self(), {:adapter_state, id, state, opts})
      Process.get(:transition_result, :ok)
    end

    def add_label(id, label), do: marker(:add, id, label)
    def remove_label(id, label), do: marker(:remove, id, label)

    defp marker(action, id, label) do
      send(self(), {:adapter_marker, action, id, label})
      Process.get(:transition_result, :ok)
    end
  end

  setup do
    for key <- [:memory_tracker_issues, :memory_tracker_recipient, :github_client_module] do
      previous = Application.fetch_env(:aiur, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:aiur, key, value)
          :error -> Application.delete_env(:aiur, key)
        end
      end)
    end

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:aiur, :memory_tracker_issues, [%Issue{id: "7", identifier: "7", state: "todo", labels: ["agent:paused"]}])
    Application.put_env(:aiur, :memory_tracker_recipient, self())
    handler = "ticket-transition-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, [:aiur, :ticket_transition], &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  def handle_event(event, measurements, meta, pid), do: send(pid, {event, measurements, meta})

  test "write_state passes expected_state and records writer" do
    log =
      capture_log(fn ->
        assert :ok = TicketTransition.write_state("7", "in-progress", writer: :retry_engine, expected_state: "todo", identifier: "T-7")
      end)

    assert {:ok, [%Issue{state: "in-progress"}]} = Tracker.fetch_issue_states_by_ids(["7"])
    assert_received {:memory_tracker_state_update, "7", "in-progress"}
    assert_received {[:aiur, :ticket_transition], measurements, meta}
    assert measurements == %{}
    assert meta == %{issue_id: "7", identifier: "T-7", action: :state, to: "in-progress", expected: "todo", writer: :retry_engine, outcome: :ok}
    assert log =~ "writer=retry_engine outcome=:ok"
    assert log =~ "expected=\"todo\""
  end

  test "none expectation and replay preserve adapter semantics" do
    Application.put_env(:aiur, :memory_tracker_issues, [%Issue{id: "7", state: ""}])
    assert :ok = TicketTransition.write_state("7", "todo", writer: :build_queue, expected_state: :none)
    assert {:error, {:stale_issue_state, :none, "todo"}} = TicketTransition.write_state("7", "todo", writer: :build_queue, expected_state: :none)
    assert {:ok, [%Issue{state: "todo"}]} = Tracker.fetch_issue_states_by_ids(["7"])
  end

  test "bound default retains two-arity injection and attributes real writes" do
    assert {:ok, state} = ReworkRequeue.init(start_paused?: true)
    assert :ok = state.state_writer.("7", "human-review")
    assert_received {[:aiur, :ticket_transition], _, %{writer: :rework_requeue, to: "human-review"}}
    double = fn id, target -> {id, target} end
    assert {:ok, injected} = ReworkRequeue.init(start_paused?: true, state_writer: double)
    assert {"7", "human-review"} = injected.state_writer.("7", "human-review")
  end

  test "error outcome is recorded and returned unchanged without retries" do
    use_client()
    Process.put(:transition_result, {:error, :boom})

    log =
      capture_log(fn ->
        assert {:error, :boom} = TicketTransition.write_state("7", "todo", writer: :retry_engine, expected_state: :none)
      end)

    assert_received {:adapter_state, "7", "todo", [expected_state: :none]}
    refute_received {:adapter_state, _, _, _}
    assert_received {[:aiur, :ticket_transition], _, %{outcome: {:error, :boom}, writer: :retry_engine}}
    assert log =~ "outcome={:error, :boom}"
  end

  test "transport and deadline failures record unknown and return original errors" do
    use_client()

    for reason <- [{:github, :timeout, %{reason: :closed}}, {:github, :transport, %{reason: :socket_failure}}, :deadline_exceeded] do
      Process.put(:transition_result, {:error, reason})

      log =
        capture_log(fn ->
          assert {:error, ^reason} = TicketTransition.write_state("7", "todo", writer: :ci_lifecycle)
        end)

      assert_received {[:aiur, :ticket_transition], _, %{outcome: :unknown}}
      assert log =~ "outcome=:unknown"
    end
  end

  test "marker writes record action and label, including failures" do
    assert :ok = TicketTransition.write_marker("7", :add, "agent:paused", writer: :pause_resume)
    assert_received {:memory_tracker_add_label, "7", "agent:paused"}
    assert_received {[:aiur, :ticket_transition], _, %{action: :add, to: "agent:paused", writer: :pause_resume, outcome: :ok}}
    assert :ok = TicketTransition.write_marker("7", :remove, "agent:paused", writer: :pause_resume)
    assert {:ok, [%Issue{labels: []}]} = Tracker.fetch_issue_states_by_ids(["7"])
    assert_received {[:aiur, :ticket_transition], _, %{action: :remove, to: "agent:paused", writer: :pause_resume, outcome: :ok}}
    use_client()
    Process.put(:transition_result, {:error, {:github, :timeout, %{reason: :timeout}}})
    assert {:error, {:github, :timeout, %{reason: :timeout}}} = TicketTransition.write_marker("7", :add, "agent:paused", writer: :pause_resume)
    assert_received {[:aiur, :ticket_transition], _, %{action: :add, outcome: :unknown}}
  end

  test "writer is required before adapter IO" do
    assert_raise KeyError, fn -> TicketTransition.write_state("7", "todo", []) end
    assert_raise MatchError, fn -> TicketTransition.write_marker("7", :add, "agent:paused", writer: "cli") end
    refute_received {:memory_tracker_state_update, _, _}
    refute_received {:memory_tracker_add_label, _, _}
  end

  test "control tracker reads remain available after dynamic dispatch is replaced" do
    server = start_supervised!({ControlServer, nil})
    assert {:ok, [%Issue{id: "7", state: "todo"}]} = PauseResume.reset_dispatch_budget(server, "7")
  end

  defp use_client do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    Application.put_env(:aiur, :github_client_module, Client)
  end
end

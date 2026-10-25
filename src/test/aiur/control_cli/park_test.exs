defmodule Aiur.ControlCLI.ParkTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI

  setup do
    :ok = write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:aiur, :memory_tracker_issues, [])
    Application.put_env(:aiur, :memory_tracker_recipient, self())

    orchestrator = Process.whereis(Orchestrator)
    original = :sys.get_state(orchestrator)
    on_exit(fn -> if Process.alive?(orchestrator), do: :sys.replace_state(orchestrator, fn _ -> original end) end)

    issue = %Issue{id: "2952", identifier: "2952", state: "in-progress", paused: true}
    entry = %{issue: issue, identifier: issue.identifier, pid: nil, ref: nil, paused_reason: :operator, control: %{status: :paused}}
    :sys.replace_state(orchestrator, &%{&1 | running: %{issue.id => entry}, tracker_tasks: %{}})

    :ok
  end

  test "park reports pending, already parked, and refused targets with exit markers" do
    pending = capture_io(fn -> AgentControlCLI.park(["2952"]) end)
    assert pending =~ "parking #2952; tracker marker write pending"
    assert pending =~ "__AIUR_CONTROL_EXIT__:0"
    assert_receive {:memory_tracker_add_label, "2952", "agent:parked"}, 1_000

    assert await_orchestrator_state(Process.whereis(Orchestrator), fn state ->
             get_in(state.running, ["2952", :operator_parked]) == true
           end)

    already_parked = capture_io(fn -> AgentControlCLI.park(["2952"]) end)
    assert already_parked =~ "#2952 already parked"
    assert already_parked =~ "__AIUR_CONTROL_EXIT__:0"

    refused = capture_io(fn -> capture_io(:stderr, fn -> AgentControlCLI.park(["missing"]) end) end)
    assert refused =~ "__AIUR_CONTROL_ERROR__:✗ #missing could not be parked: no running agent"
    assert refused =~ "__AIUR_CONTROL_EXIT__:1"
  end

  # The RPC hop returns only stdout; a stderr-only reason reached the operator as
  # "returned no diagnostic output" (#4694).
  test "park names why a paused ci-wait ticket holds no reservation" do
    :sys.replace_state(Process.whereis(Orchestrator), fn state ->
      update_in(state.running["2952"].issue, &%{&1 | state: "ci-wait"})
    end)

    refused = capture_io(fn -> capture_io(:stderr, fn -> AgentControlCLI.park(["2952"]) end) end)
    assert refused =~ "__AIUR_CONTROL_ERROR__:✗ #2952 could not be parked: its pause (CI wait"
    assert refused =~ "does not hold a slot"
    assert refused =~ "__AIUR_CONTROL_EXIT__:1"
  end
end

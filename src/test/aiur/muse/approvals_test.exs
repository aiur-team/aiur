defmodule Aiur.Muse.ApprovalsTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.Muse.Approvals

  @session "session-a"
  @approval "approval-a"
  @requirement %{"approvalId" => @approval, "sourceIndex" => 0}

  setup do
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, {:line, 16_384}, :exit_status])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    %{port: port, state: Approvals.new(%{thread_id: @session, port: port})}
  end

  test "presentation receipt is not consent and a matching resolution completes delivery", %{port: port, state: state} do
    state = Approvals.observe(state, request(@requirement, 9))
    assert %{"id" => 9, "result" => %{}} = sent(port)
    refute_received {:delivered, _}, 0
    refute_received {:failed, _}, 0

    state = deliver(state, @requirement, "allow_once")
    decision = sent(port)
    assert decision["method"] == "approval/decide"
    assert decision["params"]["requirementId"] == @requirement
    assert decision["params"]["sessionId"] == @session

    state = Approvals.observe(state, %{"id" => decision["id"], "result" => %{"status" => "accepted", "commandId" => decision["params"]["commandId"]}})
    refute_received {:delivered, _}, 0
    refute_received {:failed, _}, 0

    state = Approvals.observe(state, resolved(decision["params"]["commandId"]))
    assert_receive {:delivered, %{approval_id: @approval, command_id: command_id}}, 1000
    assert command_id == decision["params"]["commandId"]
    refute Approvals.pending?(state)
  end

  test "wrong session, stale requirement, and unknown choice never submit", %{port: port, state: state} do
    wrong_session = put_in(request(@requirement)["params"]["sessionId"], "session-b")
    state = Approvals.observe(state, wrong_session)
    refute Approvals.pending?(state)
    state = deliver(state, @requirement, "allow_once")
    assert_receive {:failed, {:invalid_native_response, :stale_or_invalid_approval_choice}}, 1000
    refute_sent(port)

    state = Approvals.observe(state, request(@requirement))
    stale = %{"approvalId" => @approval, "sourceIndex" => 1}
    state = deliver(state, stale, "allow_once")
    assert_receive {:failed, {:invalid_native_response, :stale_or_invalid_approval_choice}}, 1000
    _state = deliver(state, @requirement, "unknown_choice")
    assert_receive {:failed, {:invalid_native_response, :stale_or_invalid_approval_choice}}, 1000
    refute_sent(port)
  end

  test "a changed requirement invalidates an in-flight decision and fences the next stage", %{port: port, state: state} do
    state = Approvals.observe(state, request(@requirement))
    state = deliver(state, @requirement, "allow_once")
    first = sent(port)
    next_requirement = %{"approvalId" => @approval, "sourceIndex" => 1}
    state = Approvals.observe(state, request(next_requirement))
    assert_receive {:failed, {:invalid_native_response, :requirement_changed}}, 1000

    state = Approvals.observe(state, resolved(first["params"]["commandId"]))
    refute_received {:delivered, _}, 0
    assert Approvals.pending?(state)
    state = deliver(state, @requirement, "allow_once")
    assert_receive {:failed, {:invalid_native_response, :stale_or_invalid_approval_choice}}, 1000
    refute_sent(port)

    state = deliver(state, next_requirement, "allow_once")
    assert sent(port)["params"]["requirementId"] == next_requirement
    assert Approvals.pending?(state)
  end

  test "a requirement belonging to another approval cannot be presented or submitted", %{port: port, state: state} do
    foreign = %{"approvalId" => "different-approval", "sourceIndex" => 0}
    state = Approvals.observe(state, request(foreign, 11))
    refute Approvals.pending?(state)
    _state = deliver(state, foreign, "allow_once")
    assert_receive {:failed, {:invalid_native_response, :stale_or_invalid_approval_choice}}, 1000
    refute_sent(port)
  end

  test "unknown choice shapes cannot crash an Executor response", %{port: port, state: state} do
    frame = put_in(request(@requirement)["params"]["availableChoices"], [nil, "future-choice"])
    state = Approvals.observe(state, frame)
    _state = deliver(state, @requirement, "allow_once")
    assert_receive {:failed, {:invalid_native_response, :stale_or_invalid_approval_choice}}, 1000
    refute_sent(port)
  end

  test "a replayed older request cannot roll the current stage backward", %{port: port, state: state} do
    newer = %{"approvalId" => @approval, "sourceIndex" => 1}
    state = Approvals.observe(state, request(newer))
    state = Approvals.observe(state, request(@requirement))

    state = deliver(state, @requirement, "allow_once")
    assert_receive {:failed, {:invalid_native_response, :stale_or_invalid_approval_choice}}, 1000
    refute_sent(port)

    _state = deliver(state, newer, "allow_once")
    assert sent(port)["params"]["requirementId"] == newer
  end

  test "a resolution from another session cannot settle the command", %{port: port, state: state} do
    state = Approvals.observe(state, request(@requirement))
    state = deliver(state, @requirement, "allow_once")
    decision = sent(port)
    other = put_in(resolved(decision["params"]["commandId"])["params"]["sessionId"], "session-b")
    state = Approvals.observe(state, other)
    refute_received {:delivered, _}, 0
    assert :ok = Approvals.close(state)
    assert_receive {:failed, :native_approval_unconfirmed}, 1000
  end

  test "resolution from another command cannot claim this submission", %{port: port, state: state} do
    state = Approvals.observe(state, request(@requirement))
    state = deliver(state, @requirement, "allow_once")
    assert %{"method" => "approval/decide"} = sent(port)
    state = Approvals.observe(state, resolved("different-command"))
    assert_receive {:failed, {:invalid_native_response, :resolved_elsewhere}}, 1000
    refute_received {:delivered, _}, 0
    refute Approvals.pending?(state)
  end

  test "close returns an unconfirmed submission to the outer delivery queue", %{port: port, state: state} do
    state = Approvals.observe(state, request(@requirement))
    state = deliver(state, @requirement, "allow_once")
    assert %{"method" => "approval/decide"} = sent(port)
    assert :ok = Approvals.close(state)
    assert_receive {:failed, :native_approval_unconfirmed}, 1000
    refute_received {:delivered, _}, 0
  end

  defp request(requirement, id \\ nil) do
    frame = %{
      "jsonrpc" => "2.0",
      "method" => "approval/request",
      "params" => %{
        "sessionId" => @session,
        "approvalId" => @approval,
        "currentRequirementId" => requirement,
        "availableChoices" => [%{"choiceId" => "allow_once", "label" => "Allow once"}]
      }
    }

    if id, do: Map.put(frame, "id", id), else: frame
  end

  defp resolved(command_id) do
    %{"jsonrpc" => "2.0", "method" => "approval/resolved", "params" => %{"sessionId" => @session, "approvalId" => @approval, "decidedByCommandId" => command_id, "decision" => "approved"}}
  end

  defp deliver(state, requirement, choice) do
    token = Approvals.requirement_token(requirement)
    Approvals.deliver(state, "/approve #{@approval} #{token} #{choice}", fn metadata -> send(self(), {:delivered, metadata}) end, fn reason -> send(self(), {:failed, reason}) end)
  end

  defp sent(port) do
    receive_barrier({^port, {:data, {:eol, line}}})
    Jason.decode!(line)
  end

  defp refute_sent(port) do
    assert Port.command(port, "approval-test-barrier\n")
    receive_barrier({^port, {:data, {:eol, line}}})
    assert line == "approval-test-barrier"
  end
end

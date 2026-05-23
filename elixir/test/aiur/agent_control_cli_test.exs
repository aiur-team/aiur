defmodule Aiur.AgentControlCLITest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI

  defp running_entry(issue_id, identifier, status, pid \\ self()) do
    %{
      pid: pid,
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{id: issue_id, identifier: identifier, state: "In Progress", title: "Issue #{identifier}"},
      control: %{
        can_interrupt: true,
        safe_checkpoints: [:notification],
        status: status
      },
      session_id: "thread-#{identifier}",
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      started_at: DateTime.utc_now()
    }
  end

  setup do
    pid = Process.whereis(Orchestrator)
    original_state = :sys.get_state(pid)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{}, last_polled_issues: %{}, session_max_concurrent_agents: nil}
    end)

    on_exit(fn ->
      if Process.alive?(pid) do
        :sys.replace_state(pid, fn _state -> original_state end)
      end
    end)

    {:ok, orchestrator: pid}
  end

  test "pause reports already paused agents as a successful no-op", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :paused)}}
    end)

    output = capture_io(fn -> AgentControlCLI.pause(["44"]) end)

    assert output =~ "aiur: already paused #44"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    refute_receive {:pause_agent, _request_id}, 100
  end

  test "pause and resume emit control messages and successful summaries", %{orchestrator: pid} do
    parent = self()

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working, parent)}}
    end)

    pause_output = capture_io(fn -> AgentControlCLI.pause(["44"]) end)

    assert pause_output =~ "aiur: paused #44 (was: running)"
    assert pause_output =~ "__AIUR_CONTROL_EXIT__:0"
    assert_receive {:pause_agent, pause_request_id} when is_integer(pause_request_id), 500

    send(pid, {:worker_control_state, "issue-44", :paused})

    assert [%{identifier: "repo#44", state: :paused}] = Orchestrator.status(Orchestrator, 1_000)

    resume_output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)

    assert resume_output =~ "aiur: resumed #44 (was: paused)"
    assert resume_output =~ "__AIUR_CONTROL_EXIT__:0"
    assert_receive {:resume_agent, resume_request_id} when is_integer(resume_request_id), 500
  end

  test "mixed target results exit successfully when at least one target works", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :paused)}}
    end)

    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.pause(["44", "45"]) end)

        assert output =~ "aiur: already paused #44"
        assert output =~ "__AIUR_CONTROL_EXIT__:0"
      end)

    assert stderr =~ "aiur: failed to pause #45 (no running agent)"
  end
end

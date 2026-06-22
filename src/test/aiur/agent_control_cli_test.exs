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

  test "status prints empty and populated tables", %{orchestrator: pid} do
    empty_output = capture_io(fn -> AgentControlCLI.status() end)

    assert empty_output =~ "ISSUE STATE  TITLE"
    assert empty_output =~ "(no active agents)"
    assert empty_output =~ "__AIUR_CONTROL_EXIT__:0"

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-44" => running_entry("issue-44", "repo#44", :working),
            "88" => running_entry("88", "", :working),
            "issue-alpha" => running_entry("issue-alpha", "worker-alpha", :working)
          }
      }
    end)

    populated_output = capture_io(fn -> AgentControlCLI.status() end)

    assert populated_output =~ "ISSUE STATE   TITLE"
    assert populated_output =~ "#44    running Issue repo#44"
    assert populated_output =~ "#88    running Issue "
    assert populated_output =~ "worker-alpha running Issue worker-alpha"
    assert populated_output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  test "all targets report empty successful selections" do
    pause_output = capture_io(fn -> AgentControlCLI.pause(:all) end)
    resume_output = capture_io(fn -> AgentControlCLI.resume(:all) end)

    assert pause_output =~ "aiur: no running agents"
    assert pause_output =~ "__AIUR_CONTROL_EXIT__:0"
    assert resume_output =~ "aiur: no paused agents"
    assert resume_output =~ "__AIUR_CONTROL_EXIT__:0"
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

  test "all failed targets exit non-zero" do
    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.resume(["45"]) end)

        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "aiur: failed to resume #45 (no running agent)"
  end

  test "running resume is a successful no-op", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}}
    end)

    output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)

    assert output =~ "aiur: already running #44"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  test "idle resume starts queued issues", %{orchestrator: pid} do
    Application.put_env(:aiur, :agent_control_cli_resume_fun, fn "repo#47" -> {:ok, :started} end)

    on_exit(fn ->
      Application.delete_env(:aiur, :agent_control_cli_resume_fun)
    end)

    issue = %Issue{id: "issue-47", identifier: "repo#47", state: "In Progress", title: "Queued"}

    :sys.replace_state(pid, fn state ->
      %{state | running: %{}, last_polled_issues: %{"issue-47" => issue}, session_max_concurrent_agents: 1}
    end)

    output = capture_io(fn -> AgentControlCLI.resume(["47"]) end)

    assert output =~ "aiur: started #47 (was: idle)"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  test "idle resume reports non-resumable issues", %{orchestrator: pid} do
    issue = %Issue{id: "issue-48", identifier: "repo#48", state: "Done", title: "Closed"}

    :sys.replace_state(pid, fn state ->
      %{state | running: %{}, last_polled_issues: %{"issue-48" => issue}}
    end)

    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.resume(["48"]) end)

        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "aiur: failed to resume #48 (not resumable)"
  end

  test "fallback display handles nil targets" do
    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.resume([nil]) end)

        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "aiur: failed to resume  (no running agent)"
  end

  test "control failures format orchestrator reasons", %{orchestrator: pid} do
    dead_pid = spawn(fn -> :ok end)
    ref = Process.monitor(dead_pid)
    assert_receive {:DOWN, ^ref, :process, ^dead_pid, _reason}, 500

    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 1,
          running: %{
            "issue-active" => running_entry("issue-active", "repo#44", :working),
            "issue-dead" => running_entry("issue-dead", "repo#45", :working, dead_pid),
            "issue-paused" => running_entry("issue-paused", "repo#46", :paused)
          }
      }
    end)

    pause_stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.pause(["45"]) end)

        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    resume_stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.resume(["46"]) end)

        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert pause_stderr =~ "aiur: failed to pause #45 (agent finished)"
    assert resume_stderr =~ "aiur: failed to resume #46 (max concurrent agents reached)"
  end

  test "message delivers operator text to a running agent and reports success", %{orchestrator: pid} do
    parent = self()

    Application.put_env(:aiur, :agent_control_cli_message_fun, fn identifier, text ->
      send(parent, {:messaged, identifier, text})
      {:ok, 7}
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_message_fun) end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}}
    end)

    output = capture_io(fn -> AgentControlCLI.message("44", "ship it") end)

    assert output =~ "aiur: messaged #44"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    # Delivered through the canonical identifier, not the bare issue number.
    assert_receive {:messaged, "repo#44", "ship it"}, 500
  end

  test "message to a non-running issue fails with a clear error" do
    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.message("45", "hello") end)

        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "aiur: failed to message #45 (no running agent)"
  end

  test "message surfaces delivery errors with a non-zero exit", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}}
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_message_fun) end)

    for {reason, expected} <- [
          {:empty_message, "message is empty"},
          {:message_too_long, "message is too long"},
          {:invalid_message, "invalid message"}
        ] do
      Application.put_env(:aiur, :agent_control_cli_message_fun, fn _identifier, _text ->
        {:error, reason}
      end)

      stderr =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> AgentControlCLI.message("44", "anything") end)

          assert output =~ "__AIUR_CONTROL_EXIT__:1"
        end)

      assert stderr =~ "aiur: failed to message #44 (#{expected})"
    end
  end

  test "message reports a clear error when the orchestrator is unavailable", %{orchestrator: pid} do
    Process.unregister(Orchestrator)

    try do
      stderr =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> AgentControlCLI.message("44", "hi") end)

          assert output =~ "__AIUR_CONTROL_EXIT__:1"
        end)

      assert stderr =~ "aiur: orchestrator is not running"
    after
      Process.register(pid, Orchestrator)
    end
  end

  test "unavailable orchestrator returns clear errors", %{orchestrator: pid} do
    Process.unregister(Orchestrator)

    try do
      status_stderr =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> AgentControlCLI.status() end)

          assert output =~ "__AIUR_CONTROL_EXIT__:1"
        end)

      pause_stderr =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> AgentControlCLI.pause(["44"]) end)

          assert output =~ "__AIUR_CONTROL_EXIT__:1"
        end)

      assert status_stderr =~ "aiur: orchestrator is not running"
      assert pause_stderr =~ "aiur: orchestrator is not running"
    after
      Process.register(pid, Orchestrator)
    end
  end
end

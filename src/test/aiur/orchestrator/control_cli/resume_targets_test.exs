Code.require_file("fixture.exs", __DIR__)

defmodule Aiur.Orchestrator.ControlCLI.ResumeTargetsTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.Issue

  alias Aiur.Orchestrator.ControlCLI, as: AgentControlCLI
  alias Aiur.Orchestrator.ControlCLI.TestFixture

  import TestFixture, except: [setup: 1]

  setup context do
    TestFixture.setup(context)
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

  test "idle resume reports the non-resumable tracker state", %{orchestrator: pid} do
    Application.put_env(:aiur, :agent_control_cli_resume_fun, fn "repo#48" ->
      {:error, {:tracker_state_not_resumable, "done"}}
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_resume_fun) end)

    issue = %Issue{id: "issue-48", identifier: "repo#48", state: "Done", title: "Closed"}

    :sys.replace_state(pid, fn state ->
      %{state | running: %{}, last_polled_issues: %{"issue-48" => issue}}
    end)

    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.resume(["48"]) end)

        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "aiur: failed to resume #48 (tracker state done is not resumable)"
  end

  test "idle resume explains stale tracker cache rejections", %{orchestrator: pid} do
    Application.put_env(:aiur, :agent_control_cli_resume_fun, fn "repo#49" ->
      {:error, {:stale_tracker_state, {:tracker_state_not_resumable, "human-review"}, %{cached_state: "todo", tracker_state: "human-review", changed_fields: [:state]}}}
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_resume_fun) end)

    issue = %Issue{id: "issue-49", identifier: "repo#49", state: "todo", title: "Stale"}

    :sys.replace_state(pid, fn state ->
      %{state | running: %{}, last_polled_issues: %{"issue-49" => issue}}
    end)

    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.resume(["49"]) end)
        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~
             "tracker cache was stale: cached=todo, tracker=human-review, changed=state; tracker state human-review is not resumable"
  end

  test "fallback display handles nil targets" do
    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.resume([nil]) end)

        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "aiur: failed to resume (no running agent)"
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
    assert resume_stderr =~ "aiur: failed to resume #46 (max concurrent agents reached: 2 of 1 slots used (1 active, 1 held by paused entries))"
  end

  # The message is accepted into the queue and the agent never claims it inside
  # the confirmation window — the ordinary `fallback: :queue_next` case. The
  # enqueue succeeded, so the exit stays 0, but the output must not say the
  # agent got it (#1824).
  describe "set_max_agents/1" do
    test "sets the cap and reports the new limit", %{orchestrator: pid} do
      :sys.replace_state(pid, fn state -> %{state | session_max_concurrent_agents: nil} end)

      output = capture_io(fn -> AgentControlCLI.set_max_agents(3) end)

      assert output =~ "aiur: max-agents set to 3 (0 active)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
      assert %{max: 3, session_override?: true} = Orchestrator.max_concurrent_agents(pid)
    end

    test "allows a cap below the active agent count and reports draining", %{orchestrator: pid} do
      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{
              "issue-1" => running_entry("issue-1", "repo#1", :working),
              "issue-2" => running_entry("issue-2", "repo#2", :working)
            }
        }
      end)

      output = capture_io(fn -> AgentControlCLI.set_max_agents(1) end)

      assert output =~ "aiur: max-agents set to 1 (2 active, draining)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "rejects a non-positive cap without touching the orchestrator" do
      output = capture_io(fn -> AgentControlCLI.set_max_agents(0) end)

      assert output =~ "__AIUR_CONTROL_ERROR__:aiur: max-agents must be a positive integer"
      assert output =~ "__AIUR_CONTROL_EXIT__:1"
    end

    test "a write against a busy orchestrator announces the wait and names what it waited for (#2137)", %{orchestrator: pid} do
      previous = Application.get_env(:aiur, :agent_control_cli_busy_mailbox_threshold)
      Application.put_env(:aiur, :agent_control_cli_busy_mailbox_threshold, 0)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:aiur, :agent_control_cli_busy_mailbox_threshold),
          else: Application.put_env(:aiur, :agent_control_cli_busy_mailbox_threshold, previous)
      end)

      # Suspend the orchestrator to stand in for the post-restart initial
      # GitHub reconciliation poll that can wedge its mailbox past the 5s
      # control-call budget, and drop a message into its mailbox so the busy
      # heuristic fires. The CLI must report progress instead of appearing hung,
      # and the failure must say what the write was waiting on, not just
      # "orchestrator timed out" (#2137).
      :sys.suspend(pid)
      send(pid, :stand_in_for_poll_work)

      try do
        output = capture_io(fn -> AgentControlCLI.set_max_agents(3) end)

        assert output =~ "aiur: waiting for the orchestrator to become available (it is busy; mailbox="
        assert output =~ "aiur: failed to set max-agents (orchestrator timed out; Orchestrator"
        assert output =~ "__AIUR_CONTROL_ERROR__:"
        assert output =~ "__AIUR_CONTROL_EXIT__:124"
      after
        :sys.resume(pid)
      end
    end
  end
end

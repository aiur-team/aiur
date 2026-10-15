Code.require_file("fixture.exs", __DIR__)

defmodule Aiur.Orchestrator.ControlCLI.ResumeConfirmationTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.Orchestrator.{ControlLifecycle, StatusReport}

  alias Aiur.Orchestrator.ControlCLI, as: AgentControlCLI
  alias Aiur.Orchestrator.ControlCLI.TestFixture

  import TestFixture, except: [setup: 1]

  setup context do
    TestFixture.setup(context)
  end

  test "running resume still clears a tracker pause that reconciliation has not applied", %{orchestrator: pid} do
    parent = self()

    Application.put_env(:aiur, :agent_control_cli_resume_fun, fn "repo#44" ->
      send(parent, :resume_called)
      {:ok, :resumed}
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_resume_fun) end)

    entry =
      "issue-44"
      |> running_entry("repo#44", :working)
      |> put_in([:issue, Access.key(:paused)], true)
      |> put_in([:issue, Access.key(:labels)], ["agent:in-progress", "agent:paused"])

    :sys.replace_state(pid, fn state -> %{state | running: %{"issue-44" => entry}} end)

    output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)

    assert_receive :resume_called, 1000
    assert output =~ "aiur: resumed #44 (was: running)"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  # #1634's headline defect. The orchestrator answers `{:ok, :resumed}` as soon
  # as the resume is queued for the agent, so a CLI that prints on that reply
  # reports a completed resume for an agent that is still paused — exactly what
  # left three agents in `operator_pause` while the CLI reported no failure.
  test "a queued resume still pending at the confirmation deadline reports an unknown outcome", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      entry = modern_running_entry("issue-44", "repo#44", :paused) |> Map.put(:paused_reason, :operator_pause)

      %{
        state
        | running: %{"issue-44" => entry},
          control_lifecycle: %ControlLifecycle{}
      }
    end)

    stderr =
      capture_io(:stderr, fn ->
        output =
          with_resume_confirm_timeout(3_000, fn ->
            capture_io(fn -> AgentControlCLI.resume(["44"]) end)
          end)

        refute output =~ "aiur: resumed #44"
        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "aiur: resume request accepted for #44"
    assert stderr =~ "confirmation window elapsed"
    assert stderr =~ "outcome is unknown"
    assert stderr =~ "control status remains paused"
    refute stderr =~ "resume dropped"
    refute stderr =~ "resume declined"
    assert [%{identifier: "repo#44", state: :paused}] = Orchestrator.status(Orchestrator, 1_000)
  end

  test "an expired queued resume is reported as dropped, not declined", %{orchestrator: pid} do
    Application.put_env(:aiur, :agent_control_cli_resume_fun, fn "repo#44" -> {:ok, {:resumed, 997}} end)
    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_resume_fun) end)

    entry = modern_running_entry("issue-44", "repo#44", :paused) |> Map.put(:paused_reason, :operator_pause)

    attrs = %{
      request_id: 997,
      issue_id: "issue-44",
      tracker_identity: entry.issue.tracker_identity,
      action: :resume,
      generation: 1,
      expected_status: :paused,
      expected_version: 0,
      requester: :operator
    }

    lifecycle = ControlLifecycle.new(now: ~U[2026-08-11 12:00:00Z])
    {:ok, _request, lifecycle} = ControlLifecycle.request(lifecycle, attrs, now: ~U[2026-08-11 12:00:00Z])
    {:ok, _request, lifecycle} = ControlLifecycle.accept(lifecycle, 997, 1, now: ~U[2026-08-11 12:00:01Z])
    {:ok, _request, lifecycle} = ControlLifecycle.expire(lifecycle, 997, :timeout, now: ~U[2026-08-11 12:00:02Z])

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => entry}, control_lifecycle: lifecycle}
    end)

    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)
        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "resume dropped (timeout)"
    assert stderr =~ "control status remains paused"
    refute stderr =~ "resume declined"
    refute stderr =~ "outcome is unknown"
  end

  test "a queued resume the agent declines reports the held status and condition", %{orchestrator: pid} do
    agent = declining_agent("issue-44")

    entry =
      "issue-44"
      |> modern_running_entry("repo#44", :paused, agent)
      |> Map.put(:paused_reason, :max_agent_duration)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{"issue-44" => entry},
          control_lifecycle: %ControlLifecycle{}
      }
    end)

    stderr =
      capture_io(:stderr, fn ->
        output =
          with_resume_confirm_timeout(3_000, fn ->
            capture_io(fn -> AgentControlCLI.resume(["44"]) end)
          end)

        refute output =~ "aiur: resumed #44"
        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "aiur: resume declined for #44"
    assert stderr =~ "control status remains paused"
    assert stderr =~ "maximum agent duration reached"
    assert stderr =~ "worker could not release the active pause containment"
    refute stderr =~ "resume dropped"
    refute stderr =~ "unconfirmed"
  end

  test "a queued resume with no correlatable lifecycle says why is unknown", %{orchestrator: pid} do
    Application.put_env(:aiur, :agent_control_cli_resume_fun, fn "repo#44" -> {:ok, {:resumed, 999}} end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{"issue-44" => modern_running_entry("issue-44", "repo#44", :paused)},
          control_lifecycle: %ControlLifecycle{}
      }
    end)

    # This test owns the readable-status premise. Building the row through the
    # production reporter keeps its shape faithful while avoiding an unrelated
    # SnapshotStore transport timeout selecting the distinct unreadable-status
    # diagnostic path.
    readable_statuses =
      pid
      |> :sys.get_state()
      |> StatusReport.agent_statuses(fn _timeout -> {:unavailable, nil} end)

    assert [%{identifier: "repo#44", state: :paused, control: control}] = readable_statuses
    assert control.status == :paused
    assert Map.get(control, :latest_control) == nil
    assert Map.get(control, :latest_resume_control) == nil
    assert Map.get(control, :recent_controls, []) == []

    Application.put_env(:aiur, :agent_control_cli_confirmation_status_fun, fn _server, _timeout -> readable_statuses end)

    on_exit(fn ->
      Application.delete_env(:aiur, :agent_control_cli_resume_fun)
      Application.delete_env(:aiur, :agent_control_cli_confirmation_status_fun)
    end)

    stderr =
      capture_io(:stderr, fn ->
        output =
          with_resume_confirm_timeout(3_000, fn ->
            capture_io(fn -> AgentControlCLI.resume(["44"]) end)
          end)

        assert output =~ "__AIUR_CONTROL_EXIT__:1\n"
        refute output =~ "__AIUR_CONTROL_EXIT__:124"
      end)

    assert stderr =~ "why it was not applied could not be determined"
    assert stderr =~ "missing control outcome"
    assert stderr =~ "control status remains paused"
    assert stderr =~ "pause condition: unknown"
    assert stderr =~ "outcome is unknown"
    refute stderr =~ "resume dropped"
    refute stderr =~ "resume declined"
  end

  test "a queued resume ignores a terminal outcome for a different request", %{orchestrator: pid} do
    Application.put_env(:aiur, :agent_control_cli_resume_fun, fn "repo#44" -> {:ok, {:resumed, 999}} end)
    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_resume_fun) end)

    entry = modern_running_entry("issue-44", "repo#44", :paused)

    attrs = %{
      request_id: 998,
      issue_id: "issue-44",
      tracker_identity: entry.issue.tracker_identity,
      action: :resume,
      generation: 1,
      expected_status: :paused,
      expected_version: 0,
      requester: :operator
    }

    lifecycle = ControlLifecycle.new(now: ~U[2026-08-11 12:00:00Z])
    {:ok, _request, lifecycle} = ControlLifecycle.request(lifecycle, attrs, now: ~U[2026-08-11 12:00:00Z])
    {:ok, _request, lifecycle} = ControlLifecycle.accept(lifecycle, 998, 1, now: ~U[2026-08-11 12:00:01Z])
    {:ok, _request, lifecycle} = ControlLifecycle.reject(lifecycle, 998, :not_eligible, now: ~U[2026-08-11 12:00:02Z])

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => entry}, control_lifecycle: lifecycle}
    end)

    stderr =
      capture_io(:stderr, fn ->
        output = with_resume_confirm_timeout(3_000, fn -> capture_io(fn -> AgentControlCLI.resume(["44"]) end) end)
        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "mismatched control outcome"
    assert stderr =~ "outcome is unknown"
    refute stderr =~ "resume declined"
    refute stderr =~ "resume dropped"
  end

  test "a superseded queued resume reports its exact correlated decline", %{orchestrator: pid} do
    Application.put_env(:aiur, :agent_control_cli_resume_fun, fn "repo#44" -> {:ok, {:resumed, 997}} end)
    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_resume_fun) end)

    entry = modern_running_entry("issue-44", "repo#44", :paused) |> Map.put(:paused_reason, :operator_pause)

    attrs = %{
      request_id: 997,
      issue_id: "issue-44",
      tracker_identity: entry.issue.tracker_identity,
      action: :resume,
      generation: 1,
      expected_status: :paused,
      expected_version: 0,
      requester: :operator
    }

    lifecycle = ControlLifecycle.new(now: ~U[2026-08-11 12:00:00Z])
    {:ok, _request, lifecycle} = ControlLifecycle.request(lifecycle, attrs, now: ~U[2026-08-11 12:00:00Z])
    {:ok, _request, lifecycle} = ControlLifecycle.accept(lifecycle, 997, 1, now: ~U[2026-08-11 12:00:01Z])
    {:ok, _request, lifecycle} = ControlLifecycle.request(lifecycle, %{attrs | request_id: 998}, now: ~U[2026-08-11 12:00:02Z])
    {:ok, _request, lifecycle} = ControlLifecycle.accept(lifecycle, 998, 1, now: ~U[2026-08-11 12:00:03Z])

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => entry}, control_lifecycle: lifecycle}
    end)

    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)
        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "resume declined for #44"
    assert stderr =~ "newer control intent superseded"
    refute stderr =~ "outcome is unknown"
    refute stderr =~ "resume dropped"
  end

  test "a deactivated row cannot masquerade as applying a queued resume", %{orchestrator: pid} do
    entry = modern_running_entry("issue-44", "repo#44", :paused) |> Map.put(:paused_reason, :operator_pause)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => entry}, control_lifecycle: ControlLifecycle.new()}
    end)

    Application.put_env(:aiur, :agent_control_cli_resume_fun, fn "repo#44" ->
      :sys.replace_state(pid, fn state ->
        attrs = %{
          request_id: 996,
          issue_id: "issue-44",
          tracker_identity: entry.issue.tracker_identity,
          action: :resume,
          generation: 1,
          expected_status: :paused,
          expected_version: 0,
          requester: :operator
        }

        {:ok, _request, lifecycle} = ControlLifecycle.request(state.control_lifecycle, attrs)
        {:ok, _request, lifecycle} = ControlLifecycle.accept(lifecycle, 996, 1)
        deactivated = put_in(entry, [:control, :status], :deactivated)
        %{state | running: %{"issue-44" => deactivated}, control_lifecycle: lifecycle}
      end)

      {:ok, {:resumed, 996}}
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_resume_fun) end)

    stderr =
      capture_io(:stderr, fn ->
        output = with_resume_confirm_timeout(3_000, fn -> capture_io(fn -> AgentControlCLI.resume(["44"]) end) end)
        refute output =~ "aiur: resumed #44"
        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "outcome is unknown"
  end

  test "a queued resume the agent applies is reported as resumed", %{orchestrator: pid} do
    agent = acknowledging_agent("issue-44")

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{"issue-44" => modern_running_entry("issue-44", "repo#44", :paused, agent)},
          control_lifecycle: %ControlLifecycle{}
      }
    end)

    output =
      with_resume_confirm_timeout(3_000, fn ->
        capture_io(fn -> AgentControlCLI.resume(["44"]) end)
      end)

    assert output =~ "aiur: resumed #44 (was: paused)"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  test "resume of a duration-capped agent succeeds and clears the pause", %{orchestrator: pid} do
    # #2329 acceptance: `aiurdev resume <id>` on an agent paused by
    # `max_agent_duration` succeeds and the ticket leaves `paused`. The
    # duration marker is owned by the resume control path, so after the worker
    # acknowledges the resume the reason is cleared and the agent is working.
    agent = acknowledging_agent("issue-44")

    entry =
      "issue-44"
      |> modern_running_entry("repo#44", :paused, agent)
      |> Map.put(:paused_reason, :max_agent_duration)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{"issue-44" => entry},
          control_lifecycle: %ControlLifecycle{}
      }
    end)

    output =
      with_resume_confirm_timeout(3_000, fn ->
        capture_io(fn -> AgentControlCLI.resume(["44"]) end)
      end)

    assert output =~ "aiur: resumed #44 (was: paused)"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"

    resumed = :sys.get_state(pid).running["issue-44"]
    assert get_in(resumed, [:control, :status]) == :working
    refute Map.has_key?(resumed, :paused_reason)
  end

  test "resume exits non-zero when one of several targets fails", %{orchestrator: pid} do
    agent = acknowledging_agent("issue-44")

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{"issue-44" => modern_running_entry("issue-44", "repo#44", :paused, agent)},
          control_lifecycle: %ControlLifecycle{}
      }
    end)

    stderr =
      capture_io(:stderr, fn ->
        output =
          with_resume_confirm_timeout(3_000, fn ->
            capture_io(fn -> AgentControlCLI.resume(["44", "45"]) end)
          end)

        assert output =~ "aiur: resumed #44 (was: paused)"
        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "aiur: failed to resume #45 (no running agent)"
  end

  test "resume reports a reactivated agent as success", %{orchestrator: pid} do
    Application.put_env(:aiur, :agent_control_cli_resume_fun, fn "repo#44" -> {:ok, :reactivated} end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_resume_fun) end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :paused)}}
    end)

    output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)

    assert output =~ "aiur: reactivated #44 (was: paused)"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end
end

defmodule Aiur.Orchestrator.IssueSync.BlockedByHydrationTest do
  # Global tracker and event doubles require synchronous cases.
  use Aiur.TestSupport

  import Aiur.IssueSyncTestSupport

  alias Aiur.Orchestrator.PushRouting
  alias Aiur.Orchestrator.State

  describe "push_routing GitHub blocked_by hydration (#1631)" do
    # GitHub's poll never populates `blocked_by`, so the blockee handed to the
    # cleared-dependency resume path looks unblocked. The hydrator must reveal
    # the real blocker set before `other_open_blockers?/2` decides whether a
    # second blocker keeps the agent parked — otherwise a dependency-paused
    # GitHub agent auto-resumes while a second blocker is still open.

    test "keeps a dependency-paused agent parked when hydration reveals a second open blocker" do
      parent = self()
      agent = spawn_link(fn -> control_agent(parent) end)
      receive_barrier({:agent_started, ^agent})

      github_blockee = %{issue("blockee", "in-progress") | blocked_by: []}
      blocker = %{id: "blocker", identifier: "its-everdred/aiur#blocker", state: "done"}

      entry = %{
        pid: agent,
        identifier: github_blockee.identifier,
        issue: github_blockee,
        control: %{status: :paused, can_interrupt: true},
        paused_reason: :blocker_dependency,
        blocker_pause_generation: 1,
        blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
      }

      state = %State{running: %{github_blockee.id => entry}}

      hydrator = fn _issue ->
        {:ok,
         %{
           github_blockee
           | blocked_by: [
               blocker,
               %{id: "other", identifier: "its-everdred/aiur#other", state: "in-progress"}
             ]
         }}
      end

      result =
        PushRouting.maybe_resume_blockee_on_cleared_dependency(
          state,
          github_blockee,
          blocker,
          :terminal,
          hydrator
        )

      control_agent_barrier(agent)
      refute_received {:resume_agent, _}
      assert get_in(result.running, [github_blockee.id, :control, :status]) == :paused
      assert result.running[github_blockee.id].paused_reason == :blocker_dependency
    end

    test "resumes when hydration reveals only the cleared blocker" do
      parent = self()
      agent = spawn_link(fn -> control_agent(parent) end)
      receive_barrier({:agent_started, ^agent})

      github_blockee = %{issue("blockee", "in-progress") | blocked_by: []}
      blocker = %{id: "blocker", identifier: "its-everdred/aiur#blocker", state: "done"}

      entry = %{
        pid: agent,
        identifier: github_blockee.identifier,
        issue: github_blockee,
        control: %{status: :paused, can_interrupt: true},
        paused_reason: :blocker_dependency,
        blocker_pause_generation: 1,
        blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
      }

      state = %State{running: %{github_blockee.id => entry}}

      hydrator = fn _issue -> {:ok, %{github_blockee | blocked_by: [blocker]}} end

      result =
        PushRouting.maybe_resume_blockee_on_cleared_dependency(
          state,
          github_blockee,
          blocker,
          :terminal,
          hydrator
        )

      control_agent_barrier(agent)
      assert_received {:resume_agent, _request_id}
      assert get_in(result.running, [github_blockee.id, :control, :status]) == :working
      refute Map.has_key?(result.running[github_blockee.id], :paused_reason)
    end

    test "keeps a dependency-paused agent parked when hydration fails (fail-closed)" do
      parent = self()
      agent = spawn_link(fn -> control_agent(parent) end)
      receive_barrier({:agent_started, ^agent})

      github_blockee = %{issue("blockee", "in-progress") | blocked_by: []}
      blocker = %{id: "blocker", identifier: "its-everdred/aiur#blocker", state: "done"}

      entry = %{
        pid: agent,
        identifier: github_blockee.identifier,
        issue: github_blockee,
        control: %{status: :paused, can_interrupt: true},
        paused_reason: :blocker_dependency,
        blocker_pause_generation: 1,
        blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
      }

      state = %State{running: %{github_blockee.id => entry}}

      log =
        capture_log(fn ->
          result =
            PushRouting.maybe_resume_blockee_on_cleared_dependency(
              state,
              github_blockee,
              blocker,
              :terminal,
              fn _issue -> {:error, :dependencies_unavailable} end
            )

          control_agent_barrier(agent)
          refute_received {:resume_agent, _}
          assert get_in(result.running, [github_blockee.id, :control, :status]) == :paused
        end)

      assert log =~ "blocked-by hydration failed"
    end

    test "recheck path keeps a dependency-paused agent parked when hydration reveals a second blocker" do
      parent = self()
      agent = spawn_link(fn -> control_agent(parent) end)
      receive_barrier({:agent_started, ^agent})

      github_blockee = %{issue("blockee", "in-progress") | blocked_by: []}
      blocker = %{id: "blocker", identifier: "its-everdred/aiur#blocker", state: "done"}

      entry = %{
        pid: agent,
        identifier: github_blockee.identifier,
        issue: github_blockee,
        control: %{status: :paused, can_interrupt: true},
        paused_reason: :blocker_dependency,
        blocker_pause_generation: 1,
        blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
      }

      state = %State{
        running: %{github_blockee.id => entry},
        last_polled_issues: %{github_blockee.id => github_blockee}
      }

      hydrator = fn _issue ->
        {:ok,
         %{
           github_blockee
           | blocked_by: [
               blocker,
               %{id: "other", identifier: "its-everdred/aiur#other", state: "in-progress"}
             ]
         }}
      end

      result =
        PushRouting.recheck_cleared_dependency_pauses(
          state,
          fn _blockers -> {:ok, [blocker]} end,
          [github_blockee],
          hydrator
        )

      control_agent_barrier(agent)
      refute_received {:resume_agent, _}
      assert get_in(result.running, [github_blockee.id, :control, :status]) == :paused
      assert result.running[github_blockee.id].paused_reason == :blocker_dependency
    end
  end
end

defmodule Aiur.Orchestrator.Deactivate.BranchPushTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{EventTopics, PushRouting}

  describe "branch-push topic parser (subscriber wiring)" do
    test "extracts the identifier from a valid ticket.<id>.branch.push topic" do
      assert {:ok, "99"} = EventTopics.parse_branch_push_topic("ticket.99.branch.push")
      assert {:ok, "99"} = EventTopics.parse_branch_push_topic("ticket.99.branch.force-push")
    end

    test "rejects system-branch pushes (not ticket-scoped)" do
      assert :nomatch =
               EventTopics.parse_branch_push_topic("system.main.branch.push")
    end

    test "rejects nearby topics" do
      for unrelated <- [
            "ticket.99.branch.force-delete",
            "ticket.99.pr.opened",
            "ticket.99.agent.pause.request"
          ] do
        assert :nomatch = EventTopics.parse_branch_push_topic(unrelated)
      end
    end
  end

  describe "system default-branch push notifies without terminating" do
    test "topic parser extracts the branch from a system branch push" do
      assert {:ok, "main"} =
               EventTopics.parse_system_branch_push_topic("system.main.branch.push")

      assert :nomatch =
               EventTopics.parse_system_branch_push_topic("ticket.99.branch.push")
    end

    test "default branch push leaves active and paused agents running and preserves claims" do
      issue_a = %Issue{id: "issue-main-a", identifier: "560", state: "in-progress"}
      issue_b = %Issue{id: "issue-main-b", identifier: "561", state: "in-progress"}
      issue_paused = %Issue{id: "issue-paused", identifier: "562", state: "in-progress"}

      pid_a = spawn(fn -> Process.sleep(:infinity) end)
      pid_b = spawn(fn -> Process.sleep(:infinity) end)
      pid_paused = spawn(fn -> Process.sleep(:infinity) end)
      started_at = DateTime.utc_now()

      state = %Orchestrator.State{
        running: %{
          issue_a.id => %{
            pid: pid_a,
            ref: nil,
            identifier: issue_a.identifier,
            issue: issue_a,
            control: %{status: :working},
            started_at: started_at
          },
          issue_b.id => %{
            pid: pid_b,
            ref: nil,
            identifier: issue_b.identifier,
            issue: issue_b,
            control: %{status: :working},
            started_at: started_at
          },
          issue_paused.id => %{
            pid: pid_paused,
            ref: nil,
            identifier: issue_paused.identifier,
            issue: issue_paused,
            control: %{status: :paused},
            started_at: started_at
          }
        },
        claimed: MapSet.new([issue_a.id, issue_b.id, issue_paused.id]),
        retry_attempts: %{issue_a.id => %{attempt: 1}, issue_b.id => %{attempt: 1}}
      }

      try do
        next =
          PushRouting.maybe_notify_agents_on_default_branch_push(state, "main", %{
            sha: "abc123"
          })

        # No agent is terminated — the kill-on-merge fleet thrash is gone. Each
        # agent is notified via its own system.<base>.branch.push subscription and
        # keeps its in-flight turn.
        assert Map.has_key?(next.running, issue_a.id)
        assert Map.has_key?(next.running, issue_b.id)
        assert Map.has_key?(next.running, issue_paused.id)

        # Claims and retry bookkeeping survive — nothing is released or
        # re-dispatched.
        assert MapSet.member?(next.claimed, issue_a.id)
        assert MapSet.member?(next.claimed, issue_b.id)
        assert MapSet.member?(next.claimed, issue_paused.id)
        assert Map.has_key?(next.retry_attempts, issue_a.id)
        assert Map.has_key?(next.retry_attempts, issue_b.id)

        # The agent tasks are still alive (no brutal kill).
        assert Process.alive?(pid_a)
        assert Process.alive?(pid_b)
        assert Process.alive?(pid_paused)
      after
        Process.exit(pid_a, :kill)
        Process.exit(pid_b, :kill)
        Process.exit(pid_paused, :kill)
      end
    end

    test "non-default system branch push leaves active agents running" do
      issue = %Issue{id: "issue-feature", identifier: "563", state: "in-progress"}
      pid = spawn(fn -> Process.sleep(:infinity) end)
      started_at = DateTime.utc_now()

      state = %Orchestrator.State{
        running: %{
          issue.id => %{
            pid: pid,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            control: %{status: :working},
            started_at: started_at
          }
        },
        claimed: MapSet.new([issue.id]),
        retry_attempts: %{}
      }

      next = PushRouting.maybe_notify_agents_on_default_branch_push(state, "release", %{sha: "def456"})

      assert Map.has_key?(next.running, issue.id)
      assert MapSet.member?(next.claimed, issue.id)
      assert Process.alive?(pid)

      Process.exit(pid, :kill)
    end

    test "configured non-main base branch is recognized and still non-destructive" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_base_branch: "trunk")

      issue = %Issue{id: "issue-trunk", identifier: "564", state: "in-progress"}
      pid = spawn(fn -> Process.sleep(:infinity) end)
      started_at = DateTime.utc_now()

      try do
        state = %Orchestrator.State{
          running: %{
            issue.id => %{
              pid: pid,
              ref: nil,
              identifier: issue.identifier,
              issue: issue,
              control: %{status: :working},
              started_at: started_at
            }
          },
          claimed: MapSet.new([issue.id]),
          retry_attempts: %{issue.id => %{attempt: 1}}
        }

        # The configured base branch (trunk) is the branch this reaction keys
        # on, but the notify-only behavior never terminates the agent.
        after_trunk =
          PushRouting.maybe_notify_agents_on_default_branch_push(state, "trunk", %{sha: "trunk123"})

        assert Map.has_key?(after_trunk.running, issue.id)
        assert MapSet.member?(after_trunk.claimed, issue.id)
        assert Map.has_key?(after_trunk.retry_attempts, issue.id)
        assert Process.alive?(pid)
      after
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end
    end
  end
end

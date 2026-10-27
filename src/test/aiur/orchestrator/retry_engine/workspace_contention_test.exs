defmodule Aiur.Orchestrator.RetryEngine.WorkspaceContentionTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.State
  alias Aiur.Workspace.Ownership

  describe "workspace ownership contention" do
    test "releases a contender when ownership was released before its wait row was installed" do
      issue_id = "issue-ownership-race"
      identifier = "repo#ownership-race-#{System.unique_integer([:positive])}"

      state = %State{
        claimed: MapSet.new([issue_id]),
        dispatch_recovery: %{
          workspace_ownership: %{waits: %{}, ready: %{}},
          codex_thrash_budget: %{}
        }
      }

      next =
        RetryEngine.wait_for_workspace_ownership(
          state,
          issue_id,
          identifier,
          :none,
          :waiting
        )

      refute MapSet.member?(next.claimed, issue_id)
      assert Map.has_key?(next.dispatch_recovery.workspace_ownership.ready, issue_id)
    end

    test "re-subscribes when ownership changes hands before its wait row is installed" do
      issue_id = "issue-ownership-handoff"
      identifier = "repo#ownership-handoff-#{System.unique_integer([:positive])}"
      assert {:ok, first_owner} = Ownership.claim(identifier)

      on_exit(fn -> Ownership.release(first_owner) end)

      # This is the runner's original subscription. Its availability notice is
      # deliberately consumed before the orchestrator installs the row.
      assert {:waiting, _guardian, _generation} = Ownership.wait_for_release(identifier, self())
      assert :ok = Ownership.release(first_owner)
      assert_receive {:workspace_ownership_available, ^identifier, _guardian, _generation}, 1000

      assert {:ok, second_owner} = Ownership.claim(identifier)
      on_exit(fn -> Ownership.release(second_owner) end)

      state = %State{
        claimed: MapSet.new([issue_id]),
        dispatch_recovery: %{
          workspace_ownership: %{waits: %{}, ready: %{}},
          codex_thrash_budget: %{}
        }
      }

      next =
        RetryEngine.wait_for_workspace_ownership(
          state,
          issue_id,
          identifier,
          first_owner,
          :waiting
        )

      assert MapSet.member?(next.claimed, issue_id)
      assert :ok = Ownership.release(second_owner)
      assert_receive {:workspace_ownership_available, ^identifier, _guardian, _generation}, 1000
    end

    test "parks a contender without consuming retry or thrash budget when its runner exits first" do
      issue_id = "issue-ownership"
      identifier = "repo#ownership-#{System.unique_integer([:positive])}"
      assert {:ok, owner_lease} = Ownership.claim(identifier)

      on_exit(fn -> Ownership.release(owner_lease) end)

      runner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      ref = Process.monitor(runner)
      exit_ref = Process.monitor(runner)
      retry_token = make_ref()
      timer_ref = Process.send_after(self(), :unexpected_retry, 60_000)

      state = %State{
        running: %{
          issue_id => %{
            pid: runner,
            ref: ref,
            identifier: identifier,
            worker_host: "worker-a",
            prior_work: true,
            stalled_alert_outstanding: true,
            workspace_path: "/workspaces/ownership"
          }
        },
        completed: MapSet.new([issue_id]),
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{
          issue_id => %{timer_ref: timer_ref, retry_token: retry_token, attempt: 1}
        },
        dispatch_recovery: %{
          workspace_ownership: %{waits: %{}, ready: %{}},
          codex_thrash_budget: %{issue_id => %{window_start_ms: 0, count: 4}}
        }
      }

      waiting =
        RetryEngine.wait_for_workspace_ownership(
          state,
          issue_id,
          identifier,
          {:ok, owner_lease},
          :waiting
        )

      refute Map.has_key?(waiting.running, issue_id)
      refute Map.has_key?(waiting.retry_attempts, issue_id)
      refute MapSet.member?(waiting.completed, issue_id)
      assert MapSet.member?(waiting.claimed, issue_id)

      assert waiting.dispatch_recovery.workspace_ownership.waits[identifier].owner ==
               {:ok, owner_lease}

      assert waiting.dispatch_recovery.workspace_ownership.waits[identifier].prior_work
      assert waiting.dispatch_recovery.workspace_ownership.waits[identifier].stalled_alert_outstanding
      assert waiting.dispatch_recovery.codex_thrash_budget == state.dispatch_recovery.codex_thrash_budget

      ready = RetryEngine.release_workspace_wait(waiting, identifier)
      refute MapSet.member?(ready.claimed, issue_id)
      assert Map.has_key?(ready.dispatch_recovery.workspace_ownership.ready, issue_id)
      assert ready.dispatch_recovery.workspace_ownership.ready[issue_id].worker_host == "worker-a"
      assert ready.dispatch_recovery.workspace_ownership.ready[issue_id].retry_attempt == 1
      assert ready.dispatch_recovery.workspace_ownership.ready[issue_id].prior_work
      assert ready.dispatch_recovery.workspace_ownership.ready[issue_id].stalled_alert_outstanding
      assert ready.dispatch_recovery.workspace_ownership.ready[issue_id].workspace_path == "/workspaces/ownership"
      assert ready.dispatch_recovery.codex_thrash_budget == state.dispatch_recovery.codex_thrash_budget

      Process.exit(runner, :kill)
      assert_receive {:DOWN, ^exit_ref, :process, ^runner, :killed}, 2_000
      refute_receive :unexpected_retry, 100
    end

    test "rejects a stale guardian release and preserves a DOWN-first retry envelope" do
      issue_id = "issue-ownership-down-first"
      identifier = "repo#ownership-down-first-#{System.unique_integer([:positive])}"
      assert {:ok, owner_lease} = Ownership.claim(identifier)
      on_exit(fn -> Ownership.release(owner_lease) end)

      state = %State{
        running: %{
          issue_id => %{
            ref: make_ref(),
            identifier: identifier,
            started_at: DateTime.utc_now(),
            retry_attempt: 2,
            worker_host: "worker-a",
            workspace_path: "/workspaces/ownership"
          }
        },
        claimed: MapSet.new([issue_id]),
        dispatch_recovery: %{
          workspace_ownership: %{waits: %{}, ready: %{}},
          codex_thrash_budget: %{}
        }
      }

      ref = state.running[issue_id].ref
      assert {:noreply, after_down} = RetryEngine.handle_agent_down(state, ref, :killed)
      assert %{attempt: 3, worker_host: "worker-a"} = after_down.retry_attempts[issue_id]

      waiting =
        RetryEngine.wait_for_workspace_ownership(
          after_down,
          issue_id,
          identifier,
          {:ok, owner_lease},
          {:waiting, owner_lease.guardian, owner_lease.generation}
        )

      assert %{retry_attempt: 3, worker_host: "worker-a"} =
               waiting.dispatch_recovery.workspace_ownership.waits[identifier]

      stale = RetryEngine.release_workspace_wait(waiting, identifier, self(), owner_lease.generation - 1)
      assert MapSet.member?(stale.claimed, issue_id)
      assert stale.dispatch_recovery.workspace_ownership.ready == %{}

      ready =
        RetryEngine.release_workspace_wait(
          waiting,
          identifier,
          owner_lease.guardian,
          owner_lease.generation
        )

      refute MapSet.member?(ready.claimed, issue_id)
      assert %{retry_attempt: 3, worker_host: "worker-a"} = ready.dispatch_recovery.workspace_ownership.ready[issue_id]
    end
  end

  describe "preserve_running_issue_on_external_error/2" do
    test "refreshes the issue while preserving the live runner and claim" do
      issue_id = "issue-error"

      running_issue = %Issue{
        id: issue_id,
        identifier: "ERR-1",
        state: "in-progress",
        title: "Preserve the runner"
      }

      reported_issue = %{running_issue | state: "error"}

      running_entry = %{
        issue: running_issue,
        identifier: running_issue.identifier,
        control: %{status: :working},
        marker: :preserved
      }

      state = %State{
        running: %{issue_id => running_entry},
        claimed: MapSet.new([issue_id])
      }

      result = RetryEngine.preserve_running_issue_on_external_error(state, reported_issue)

      assert result.running[issue_id].issue == reported_issue
      assert result.running[issue_id].marker == :preserved
      assert result.running[issue_id].control.status == :working
      assert result.claimed == state.claimed
    end
  end
end

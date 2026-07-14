defmodule Aiur.Orchestrator.RetryEngineTest do
  use Aiur.TestSupport

  alias Aiur.{Issue, TrackerIdentity}
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.State
  alias Aiur.Workspace.Ownership

  describe "failure_retry?/1" do
    test "returns false for non-counting delay types" do
      refute RetryEngine.failure_retry?(%{delay_type: :continuation})
      refute RetryEngine.failure_retry?(%{delay_type: :capacity_wait})
      refute RetryEngine.failure_retry?(%{delay_type: :precondition})
    end

    test "returns true for failure-counted retries" do
      assert RetryEngine.failure_retry?(%{})
      assert RetryEngine.failure_retry?(%{delay_type: :other})
      assert RetryEngine.failure_retry?(%{error: "timeout"})
    end
  end

  describe "retry_delay/2" do
    test "first continuation attempt uses fixed delay" do
      assert RetryEngine.retry_delay(1, %{delay_type: :continuation}) == 1_000
    end

    test "capacity_wait uses fixed delay regardless of attempt" do
      assert RetryEngine.retry_delay(1, %{delay_type: :capacity_wait}) == 1_000
      assert RetryEngine.retry_delay(5, %{delay_type: :capacity_wait}) == 1_000
    end

    test "failure attempts use exponential backoff" do
      assert RetryEngine.retry_delay(1, %{}) == 10_000
      assert RetryEngine.retry_delay(2, %{}) == 20_000
      assert RetryEngine.retry_delay(3, %{}) == 40_000
    end
  end

  describe "failure_retry_delay/1" do
    test "doubles every attempt up to the configured cap" do
      assert RetryEngine.failure_retry_delay(1) == 10_000
      assert RetryEngine.failure_retry_delay(2) == 20_000
      assert RetryEngine.failure_retry_delay(3) == 40_000
      # Capped at max_retry_backoff_ms (default 300_000)
      assert RetryEngine.failure_retry_delay(20) == 300_000
    end
  end

  describe "normalize_retry_attempt/1" do
    test "passes through positive integers" do
      assert RetryEngine.normalize_retry_attempt(1) == 1
      assert RetryEngine.normalize_retry_attempt(5) == 5
    end

    test "returns 0 for non-positive, nil, or non-integer" do
      assert RetryEngine.normalize_retry_attempt(0) == 0
      assert RetryEngine.normalize_retry_attempt(-1) == 0
      assert RetryEngine.normalize_retry_attempt(nil) == 0
      assert RetryEngine.normalize_retry_attempt("1") == 0
    end
  end

  describe "next_retry_attempt_from_running/1" do
    test "increments a positive retry_attempt" do
      assert RetryEngine.next_retry_attempt_from_running(%{retry_attempt: 2}) == 3
      assert RetryEngine.next_retry_attempt_from_running(%{retry_attempt: 1}) == 2
    end

    test "returns nil when retry_attempt is absent or zero" do
      assert RetryEngine.next_retry_attempt_from_running(%{retry_attempt: 0}) == nil
      assert RetryEngine.next_retry_attempt_from_running(%{retry_attempt: nil}) == nil
      assert RetryEngine.next_retry_attempt_from_running(%{}) == nil
    end
  end

  describe "pop_retry_attempt_state/3" do
    test "returns attempt, metadata, and cleared state when token matches" do
      token = make_ref()

      state = %State{
        retry_attempts: %{
          "issue-1" => %{
            attempt: 3,
            retry_token: token,
            identifier: "repo#1",
            error: "boom",
            retry_poll_failures: 0,
            worker_host: nil,
            workspace_path: nil,
            tracker_identity: tracker_identity("repo#1")
          }
        }
      }

      assert {:ok, 3, metadata, next_state} =
               RetryEngine.pop_retry_attempt_state(state, "issue-1", token)

      assert metadata.identifier == "repo#1"
      assert metadata.error == "boom"
      assert metadata.tracker_identity == tracker_identity("repo#1")
      refute Map.has_key?(next_state.retry_attempts, "issue-1")
    end

    test "returns :missing when token does not match" do
      token = make_ref()

      state = %State{
        retry_attempts: %{"issue-1" => %{attempt: 1, retry_token: make_ref()}}
      }

      assert RetryEngine.pop_retry_attempt_state(state, "issue-1", token) == :missing
    end

    test "returns :missing when issue_id not in retry_attempts" do
      state = %State{retry_attempts: %{}}
      assert RetryEngine.pop_retry_attempt_state(state, "issue-x", make_ref()) == :missing
    end
  end

  describe "schedule_issue_retry/4" do
    test "stores identity supplied for a newly scheduled retry" do
      identity = tracker_identity("repo#new")

      next =
        RetryEngine.schedule_issue_retry(%State{}, "issue-new", 1, %{
          identifier: "repo#new",
          tracker_identity: identity,
          delay_type: :continuation
        })

      retry = next.retry_attempts["issue-new"]
      assert retry.tracker_identity == identity
      Process.cancel_timer(retry.timer_ref)
    end

    test "retains the prior identity across a retry/session reschedule" do
      identity = tracker_identity("repo#2")

      state = %State{
        retry_attempts: %{
          "issue-2" => %{
            attempt: 1,
            timer_ref: nil,
            tracker_identity: identity
          }
        }
      }

      next =
        RetryEngine.schedule_issue_retry(state, "issue-2", 1, %{
          identifier: "repo#2",
          delay_type: :continuation
        })

      retry = next.retry_attempts["issue-2"]
      assert retry.tracker_identity == identity
      Process.cancel_timer(retry.timer_ref)
    end

    test "clears the prior identity when a reschedule explicitly supplies nil" do
      identity = tracker_identity("repo#3")

      state = %State{
        retry_attempts: %{
          "issue-3" => %{attempt: 1, timer_ref: nil, tracker_identity: identity}
        }
      }

      next =
        RetryEngine.schedule_issue_retry(state, "issue-3", 1, %{
          identifier: "repo#3",
          tracker_identity: nil,
          delay_type: :continuation
        })

      retry = next.retry_attempts["issue-3"]
      assert retry.tracker_identity == nil
      Process.cancel_timer(retry.timer_ref)
    end
  end

  defp tracker_identity(identifier) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "I_kwDO#{identifier}",
      identifier: identifier,
      reason: nil
    }
  end

  describe "complete_issue/2" do
    test "adds to completed and removes from retry_attempts" do
      state = %State{
        completed: MapSet.new(),
        retry_attempts: %{"issue-1" => %{attempt: 1}}
      }

      result = RetryEngine.complete_issue(state, "issue-1")

      assert MapSet.member?(result.completed, "issue-1")
      refute Map.has_key?(result.retry_attempts, "issue-1")
    end
  end

  describe "release_issue_claim/2" do
    test "removes the issue_id from claimed" do
      state = %State{claimed: MapSet.new(["issue-1", "issue-2"])}
      result = RetryEngine.release_issue_claim(state, "issue-1")

      refute MapSet.member?(result.claimed, "issue-1")
      assert MapSet.member?(result.claimed, "issue-2")
    end
  end

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
      assert :waiting = Ownership.wait_for_release(identifier, self())
      assert :ok = Ownership.release(first_owner)
      assert_receive {:workspace_ownership_available, ^identifier}

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
      assert_receive {:workspace_ownership_available, ^identifier}
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

      assert waiting.dispatch_recovery.codex_thrash_budget == state.dispatch_recovery.codex_thrash_budget

      ready = RetryEngine.release_workspace_wait(waiting, identifier)
      refute MapSet.member?(ready.claimed, issue_id)
      assert Map.has_key?(ready.dispatch_recovery.workspace_ownership.ready, issue_id)
      assert ready.dispatch_recovery.workspace_ownership.ready[issue_id].worker_host == "worker-a"
      assert ready.dispatch_recovery.workspace_ownership.ready[issue_id].retry_attempt == 1
      assert ready.dispatch_recovery.workspace_ownership.ready[issue_id].workspace_path == "/workspaces/ownership"
      assert ready.dispatch_recovery.codex_thrash_budget == state.dispatch_recovery.codex_thrash_budget

      Process.exit(runner, :kill)
      assert_receive {:DOWN, ^exit_ref, :process, ^runner, :killed}, 2_000
      refute_receive :unexpected_retry
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

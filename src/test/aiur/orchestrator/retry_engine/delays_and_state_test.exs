Code.require_file("fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.RetryEngine.DelaysAndStateTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.SnapshotStore
  alias Aiur.Orchestrator.State
  import Aiur.RetryEngineFixture, only: [tracker_identity: 1]

  describe "failure_retry?/1" do
    test "returns false for non-counting delay types" do
      refute RetryEngine.failure_retry?(%{delay_type: :continuation})
      refute RetryEngine.failure_retry?(%{delay_type: :capacity_wait})
      refute RetryEngine.failure_retry?(%{delay_type: :model_limit_wait})
      refute RetryEngine.failure_retry?(%{delay_type: :precondition})
      refute RetryEngine.failure_retry?(%{delay_type: :terminal_verification})
      refute RetryEngine.failure_retry?(%{delay_type: :local_budget_hold})
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

    test "model_limit_wait uses a bounded polling delay" do
      assert RetryEngine.retry_delay(1, %{delay_type: :model_limit_wait}) >= 10_000
    end

    test "local budget holds use their reset while respecting the retry cap" do
      reset_at = DateTime.add(DateTime.utc_now(), 3_600, :second)

      assert RetryEngine.retry_delay(1, %{delay_type: :local_budget_hold, local_budget_hold: %{reset_at: reset_at}}) == 300_000
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
      last_failure_at = DateTime.utc_now()

      state = %State{
        retry_attempts: %{
          "issue-1" => %{
            attempt: 3,
            retry_token: token,
            identifier: "repo#1",
            error: "boom",
            last_failure_at: last_failure_at,
            retry_poll_failures: 0,
            worker_host: nil,
            workspace_path: nil,
            stalled_alert_outstanding: true,
            tracker_identity: tracker_identity("repo#1")
          }
        }
      }

      assert {:ok, 3, metadata, next_state} =
               RetryEngine.pop_retry_attempt_state(state, "issue-1", token)

      assert metadata.identifier == "repo#1"
      assert metadata.error == "boom"
      assert metadata.last_failure_at == last_failure_at
      assert metadata.tracker_identity == tracker_identity("repo#1")
      assert metadata.stalled_alert_outstanding
      refute Map.has_key?(next_state.retry_attempts, "issue-1")

      requeued = RetryEngine.schedule_issue_retry(next_state, "issue-1", 3, metadata)
      assert requeued.retry_attempts["issue-1"].last_failure_at == last_failure_at
      assert requeued.retry_attempts["issue-1"].stalled_alert_outstanding
      Process.cancel_timer(requeued.retry_attempts["issue-1"].timer_ref)
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

  test "publishes the retry engine's final state" do
    issue = %Issue{id: "issue-final", identifier: "MT-FINAL", state: "In Progress", title: "Final retry"}

    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "memory",
      opencode_command: System.find_executable("true")
    )

    Application.put_env(:aiur, :memory_tracker_issues, [issue])

    generation = SnapshotStore.begin_generation(self())
    retry_token = make_ref()

    state = %State{
      snapshot_key: self(),
      snapshot_generation: generation,
      snapshot_ready?: true,
      globally_paused: true,
      claimed: MapSet.new([issue.id]),
      retry_attempts: %{
        issue.id => %{
          attempt: 2,
          identifier: issue.identifier,
          retry_token: retry_token
        }
      }
    }

    assert {:noreply, final_state} = RetryEngine.handle_retry_message(state, issue.id, retry_token)

    assert %{error: "no available orchestrator slots", identifier: "MT-FINAL", retry_token: final_retry_token} =
             final_state.retry_attempts[issue.id]

    refute final_retry_token == retry_token
    Process.cancel_timer(final_state.retry_attempts[issue.id].timer_ref)

    assert eventually(
             fn ->
               match?(
                 {:current, %{retrying: [%{identifier: "MT-FINAL"}]}, _freshness},
                 Aiur.Orchestrator.dashboard_snapshot(self(), 1_000)
               )
             end,
             200
           )
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

  describe "prior_work_for_retry?/2" do
    test "does not turn a fresh zero-turn launch failure into prior work" do
      refute RetryEngine.prior_work_for_retry?(%{prior_work: false, completed_turn_count: 0}, true)
    end

    test "preserves explicit recycle provenance and completed work" do
      assert RetryEngine.prior_work_for_retry?(%{prior_work: true, completed_turn_count: 0}, true)
      assert RetryEngine.prior_work_for_retry?(%{prior_work: false, completed_turn_count: 1}, true)
      refute RetryEngine.prior_work_for_retry?(%{prior_work: true, completed_turn_count: 1}, false)
    end
  end

  defp eventually(fun, attempts)

  defp eventually(fun, attempts) when is_function(fun, 0) and attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end

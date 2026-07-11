defmodule Aiur.Orchestrator.RetryEngineTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.State

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
            workspace_path: nil
          }
        }
      }

      assert {:ok, 3, metadata, next_state} =
               RetryEngine.pop_retry_attempt_state(state, "issue-1", token)

      assert metadata.identifier == "repo#1"
      assert metadata.error == "boom"
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

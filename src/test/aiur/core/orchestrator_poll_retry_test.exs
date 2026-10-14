defmodule Aiur.Core.OrchestratorPollRetryTest do
  use Aiur.TestSupport

  import Aiur.CoreTestSupport

  defmodule RetryPollFailingGitHubClient do
    def preflight_auth, do: :ok

    def fetch_candidate_issues do
      case Application.get_env(:aiur, :retry_poll_failure_test_pid) do
        pid when is_pid(pid) -> send(pid, :retry_poll_fetch_candidate_issues)
        _ -> :ok
      end

      {:error, {:github_api_status, 403}}
    end

    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issues_by_states(_states, _opts), do: {:ok, []}
    def hydrate_blocked_by(issue), do: {:ok, issue}
  end

  test "retry poll failures do not consume agent retry budget" do
    issue_id = "issue-retry-poll-fail"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :RetryPollFailureOrchestrator)
    previous_github_client = Application.get_env(:aiur, :github_client_module)
    previous_test_pid = Application.get_env(:aiur, :retry_poll_failure_test_pid)
    previous_github_token = System.get_env("GITHUB_TOKEN")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "its-everdred/aiur",
      tracker_active_states: ["todo", "in-progress"],
      tracker_terminal_states: ["done"],
      max_retry_backoff_ms: 100
    )

    Application.put_env(:aiur, :github_client_module, RetryPollFailingGitHubClient)
    Application.put_env(:aiur, :retry_poll_failure_test_pid, self())
    System.put_env("GITHUB_TOKEN", "retry-poll-test-token")

    on_exit(fn ->
      if previous_github_client do
        Application.put_env(:aiur, :github_client_module, previous_github_client)
      else
        Application.delete_env(:aiur, :github_client_module)
      end

      if previous_test_pid do
        Application.put_env(:aiur, :retry_poll_failure_test_pid, previous_test_pid)
      else
        Application.delete_env(:aiur, :retry_poll_failure_test_pid)
      end

      restore_env("GITHUB_TOKEN", previous_github_token)
    end)

    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      stop_test_orchestrator(pid)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-POLL",
      issue: %Issue{id: issue_id, identifier: "MT-POLL", state: "in-progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :response_timeout})

    assert %{attempt: 1, retry_token: retry_token, error: "agent exited: :response_timeout"} =
             :sys.get_state(pid).retry_attempts[issue_id]

    log =
      capture_log(fn ->
        send(pid, {:retry_issue, issue_id, retry_token})
        await_orchestrator_state(pid, &(get_in(&1.retry_attempts, [issue_id, :retry_poll_failures]) == 1))

        assert %{attempt: 1, retry_poll_failures: 1, retry_token: retry_token} =
                 :sys.get_state(pid).retry_attempts[issue_id]

        send(pid, {:retry_issue, issue_id, retry_token})
        await_orchestrator_state(pid, &(get_in(&1.retry_attempts, [issue_id, :retry_poll_failures]) == 2))

        assert %{attempt: 1, retry_poll_failures: 2, retry_token: retry_token} =
                 :sys.get_state(pid).retry_attempts[issue_id]

        send(pid, {:retry_issue, issue_id, retry_token})
        await_orchestrator_state(pid, &Map.has_key?(&1.released_claims, issue_id))
      end)

    state = :sys.get_state(pid)

    refute Map.has_key?(state.retry_attempts, issue_id),
           "retry-poll exhaustion should clear the precondition retry entry"

    refute MapSet.member?(state.claimed, issue_id),
           "retry-poll exhaustion should release the claim for tracker-recovery pickup"

    assert log =~ "Retry poll failed for issue_id=#{issue_id} issue_identifier=MT-POLL"
    assert log =~ "retry_poll_failure=2/3 agent_attempt=1 tracker_error={:github_api_status, 403}"
    assert log =~ "Retrying retry-poll precondition issue_id=#{issue_id} issue_identifier=MT-POLL"
    assert log =~ "Claim released for issue_id=#{issue_id} issue_identifier=MT-POLL agent_attempt=1"
    assert log =~ "reason=tracker_retry_exhausted"
    assert log =~ "[alert] (#MT-POLL) orchestrator.claim_released"
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      stop_test_orchestrator(pid)
    end)

    :ok = :sys.suspend(pid)
    initial_state = :sys.get_state(pid)
    assert is_nil(initial_state.tick_timer_ref)
    assert is_nil(initial_state.tick_token)
    refute initial_state.poll_check_in_progress
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    # Hold the message until explicitly released; the state read below is the mailbox barrier.
    :ok = :sys.resume(pid)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end
end

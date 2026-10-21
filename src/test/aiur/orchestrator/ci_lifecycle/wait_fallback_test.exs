defmodule Aiur.Orchestrator.CiLifecycle.WaitFallbackTest do
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  alias Aiur.AgentQueueStore
  alias Aiur.CiLifecycleTestSupport.RecordingGitHubClient
  alias Aiur.Orchestrator.CiLifecycle

  setup :ci_lifecycle_setup

  describe "CI lifecycle coordination" do
    test "a matching fallback token revalidates, queues one-check guidance, and resumes" do
      test_pid = self()
      on_exit(fn -> Aiur.TestSupport.stop_test_runners(test_pid) end)

      identifier = unique_identifier("ci-rewake")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      armed =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      token = armed.ci_lifecycle.rewakes[identifier].token
      issue_fetcher = fn [^identifier] -> {:ok, [issue]} end

      next =
        CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      assert_received {:recorded, 1, {:tracker_update, ^identifier, "in-progress", [expected_state: "ci-wait"]}}
      assert_received {:recorded, 2, {:agent_queue_updated, ^identifier, _item_id, false}}
      assert_received {:recorded, 3, {:resume_agent, request_id, 101}}
      assert is_integer(request_id)

      assert next.running[identifier].issue.state == "in-progress"
      assert next.running[identifier].control.status == :paused
      assert next.running[identifier].paused_reason == :ci_wait
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)

      assert [%{body: %{events: [event]}}] = AgentQueueStore.list_pending(next.queue_store, identifier)
      assert event.topic == "ticket.#{identifier}.ci.rewake"
      assert event.source == :system
      assert event.message =~ "Check CI once"
      assert event.message =~ "Drafts never pass CI in any repository"
      assert event.message =~ "mark completed, self-reviewed work ready before waiting"
      assert event.message =~ "Before agent:human-review, require the full required-check set to pass on the current head SHA"
      assert event.message =~ "green or skipped gh pr checks aggregate alone is not a full pass"
      assert event.message =~ "return to agent:ci-wait"
    end

    test "approved queued PRs stay parked when the CI-wait fallback expires" do
      identifier = unique_identifier("ci-rewake-queued-pr")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      armed =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)
        |> put_in([Access.key(:ci_lifecycle), :poll_cache, identifier], %{
          decision: :pending,
          tracker_state: "ci-wait",
          head_sha: "queued-head",
          review_decision: "APPROVED",
          merge_queue_entry: %{"id" => "queue-entry", "state" => "AWAITING_CHECKS"}
        })

      token = armed.ci_lifecycle.rewakes[identifier].token
      assert armed.ci_lifecycle.poll_cache[identifier].review_decision == "APPROVED"
      issue_fetcher = fn [^identifier] -> {:ok, [issue]} end

      next = CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)
      sync_recorder(recorder)

      assert next.running[identifier].issue.state == "ci-wait"
      assert next.running[identifier].control.status == :paused
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)
      refute_received {:recorded, _position, _message}
    end

    test "approved auto-merge PRs stay parked when the CI-wait fallback expires" do
      identifier = unique_identifier("ci-rewake-auto-merge-pr")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      armed =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)
        |> put_in([Access.key(:ci_lifecycle), :poll_cache, identifier], %{
          decision: :pending,
          tracker_state: "ci-wait",
          head_sha: "auto-merge-head",
          review_decision: "APPROVED",
          auto_merge_request: %{"enabledAt" => "2026-10-14T00:00:00Z"}
        })

      token = armed.ci_lifecycle.rewakes[identifier].token
      issue_fetcher = fn [^identifier] -> {:ok, [issue]} end

      next = CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)
      sync_recorder(recorder)

      assert next.running[identifier].issue.state == "ci-wait"
      assert next.running[identifier].control.status == :paused
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)
      refute_received {:recorded, _position, _message}
    end

    test "stale fallback tokens cannot wake a CI-wait runner" do
      identifier = unique_identifier("ci-stale-rewake")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      armed =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      issue_fetcher = fn _ids -> flunk("stale token must not fetch tracker state") end

      next =
        CiLifecycle.handle_ci_wait_rewake(armed, identifier, make_ref(), issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      assert next == armed
      refute_received {:recorded, _position, _message}
    end

    test "a failed fallback transition replaces the expired timer token" do
      identifier = unique_identifier("ci-rewake-retry")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")
      RecordingGitHubClient.return({:error, :tracker_down})

      armed =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      expired_token = armed.ci_lifecycle.rewakes[identifier].token
      issue_fetcher = fn [^identifier] -> {:ok, [issue]} end

      next =
        CiLifecycle.handle_ci_wait_rewake(armed, identifier, expired_token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      assert_received {:recorded, 1, {:tracker_update, ^identifier, "in-progress", [expected_state: "ci-wait"]}}
      refute_received {:recorded, _position, {:resume_agent, _request_id}}
      assert %{token: replacement_token} = next.ci_lifecycle.rewakes[identifier]
      assert is_reference(replacement_token)
      refute replacement_token == expired_token
      assert next.running[identifier].control.status == :paused
    end

    test "a ci-wait pause that lost its label is resumed instead of stranded" do
      identifier = unique_identifier("ci-rewake-departed")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      armed =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      token = armed.ci_lifecycle.rewakes[identifier].token
      reworked = %{issue | state: "rework", state_labels: ["rework"]}
      issue_fetcher = fn [^identifier] -> {:ok, [reworked]} end

      next =
        CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      assert_received {:recorded, _position, {:resume_agent, request_id, 101}}
      assert is_integer(request_id)
      assert next.running[identifier].issue.state == "rework"
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)
    end

    test "a ci-wait pause whose ticket moved to human review is left to the CI poll" do
      identifier = unique_identifier("ci-rewake-departed-review")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      armed =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      token = armed.ci_lifecycle.rewakes[identifier].token
      in_review = %{issue | state: "human-review", state_labels: ["human-review"]}
      issue_fetcher = fn [^identifier] -> {:ok, [in_review]} end

      next =
        CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      refute_received {:recorded, _position, {:resume_agent, _request_id, _generation}}
      assert next.running[identifier].control.status == :paused
      assert next.running[identifier].issue.state == "human-review"
    end

    test "fallback timeout does not wake a freshly operator-paused ticket" do
      identifier = unique_identifier("ci-rewake-paused")
      recorder = start_recorder()
      issue = %{issue(identifier, "ci-wait") | paused: true}

      armed =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      token = armed.ci_lifecycle.rewakes[identifier].token
      issue_fetcher = fn [^identifier] -> {:ok, [issue]} end

      next =
        CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      refute_received {:recorded, _position, _message}
      assert next.running[identifier].control.status == :paused
      assert next.running[identifier].issue.paused
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)
    end

    test "fallback timeout does not wake a ticket routed away from this worker" do
      identifier = unique_identifier("ci-rewake-routed-away")
      recorder = start_recorder()
      issue = %{issue(identifier, "ci-wait") | assigned_to_worker: false}

      armed =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      token = armed.ci_lifecycle.rewakes[identifier].token
      issue_fetcher = fn [^identifier] -> {:ok, [issue]} end

      next =
        CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      refute_received {:recorded, _position, _message}
      assert next.running[identifier].control.status == :paused
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)
    end

    test "a deactivated runner entering CI wait gets paused_reason and fallback rewake armed" do
      identifier = unique_identifier("deactivated-ci-wait")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      state = running_state(issue, recorder, :deactivated, [])
      next = CiLifecycle.pause_issue_for_ci_wait(state, issue)

      entry = Map.fetch!(next.running, identifier)
      assert entry.control.status == :deactivated
      assert entry.paused_reason == :ci_wait
      assert %{token: token, timer_ref: timer_ref} = next.ci_lifecycle.rewakes[identifier]
      assert is_reference(token)
      assert is_reference(timer_ref)
    end

    # #2800: a trusted comment that lands after the agent has already exited
    # opens a lifecycle fence on an entry with no process to deliver it to.
    # `acknowledge_provider_delivery/2` can then never fire, so the fence used
    # to block both exits from `ci-wait` forever — and `ci-wait` is a
    # no-agent-work state, so dispatch and `aiurdev resume` both refuse it.
    test "the fallback rewake recovers a ci-wait entry fenced after its agent exited" do
      test_pid = self()
      on_exit(fn -> Aiur.TestSupport.stop_test_runners(test_pid) end)

      identifier = unique_identifier("ci-wait-fenced-exited")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      state =
        running_state(issue, recorder, :deactivated,
          pid: nil,
          ref: nil,
          lifecycle_fence: %{
            generation: 1,
            authoritative_state: "rework",
            pending_item_ids: MapSet.new([75]),
            opened_at: DateTime.utc_now()
          }
        )

      armed = CiLifecycle.pause_issue_for_ci_wait(state, issue)
      %{token: token} = armed.ci_lifecycle.rewakes[identifier]

      issue_fetcher = fn [^identifier] -> {:ok, [issue]} end

      next = CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      assert_received {:recorded, 1, {:tracker_update, ^identifier, "in-progress", [expected_state: "ci-wait"]}}
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)
    end

    test "a live fenced agent still holds the ci-wait handoff back" do
      identifier = unique_identifier("ci-wait-fenced-live")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      state =
        running_state(issue, recorder, :paused,
          paused_reason: :ci_wait,
          lifecycle_fence: %{
            generation: 1,
            authoritative_state: "rework",
            pending_item_ids: MapSet.new([75]),
            opened_at: DateTime.utc_now()
          }
        )

      armed = CiLifecycle.pause_issue_for_ci_wait(state, issue)
      %{token: token} = armed.ci_lifecycle.rewakes[identifier]

      issue_fetcher = fn [^identifier] -> {:ok, [issue]} end

      next = CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      refute_received {:recorded, _position, {:tracker_update, ^identifier, "in-progress", _opts}}
      # The live agent can still be handed the item, so the fence re-arms
      # rather than stranding the ticket.
      assert Map.has_key?(next.ci_lifecycle.rewakes, identifier)
    end

    test "a deactivated ci-wait entry is recovered by the fallback rewake" do
      test_pid = self()
      on_exit(fn -> Aiur.TestSupport.stop_test_runners(test_pid) end)

      identifier = unique_identifier("deactivated-rewake")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      state = running_state(issue, recorder, :deactivated, [])
      armed = CiLifecycle.pause_issue_for_ci_wait(state, issue)
      %{token: token} = armed.ci_lifecycle.rewakes[identifier]

      issue_fetcher = fn [^identifier] -> {:ok, [%{issue | state: "ci-wait"}]} end

      next = CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      assert_received {:recorded, 1, {:tracker_update, ^identifier, "in-progress", [expected_state: "ci-wait"]}}
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)
    end

    test "deactivated ci-wait rewake does not wake when issue is no longer in ci-wait state" do
      identifier = unique_identifier("deactivated-rewake-state-guard")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      state = running_state(issue, recorder, :deactivated, [])
      armed = CiLifecycle.pause_issue_for_ci_wait(state, issue)
      %{token: token} = armed.ci_lifecycle.rewakes[identifier]

      transitioned_issue = %{issue | state: "in-progress"}
      issue_fetcher = fn [^identifier] -> {:ok, [transitioned_issue]} end

      next = CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      refute_received {:recorded, _position, _message}
      assert next.running[identifier].control.status == :deactivated
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)
    end

    test "deactivated ci-wait rewake does not wake when issue is operator-paused" do
      identifier = unique_identifier("deactivated-rewake-paused-guard")
      recorder = start_recorder()
      issue = %{issue(identifier, "ci-wait") | paused: true}

      state = running_state(issue, recorder, :deactivated, [])
      armed = CiLifecycle.pause_issue_for_ci_wait(state, issue)
      %{token: token} = armed.ci_lifecycle.rewakes[identifier]

      issue_fetcher = fn [^identifier] -> {:ok, [issue]} end

      next = CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      refute_received {:recorded, _position, _message}
      assert next.running[identifier].control.status == :deactivated
      assert next.running[identifier].issue.paused
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)
    end

    test "deactivated ci-wait rewake does not wake when issue is routed away from this worker" do
      identifier = unique_identifier("deactivated-rewake-routed-guard")
      recorder = start_recorder()
      issue = %{issue(identifier, "ci-wait") | assigned_to_worker: false}

      state = running_state(issue, recorder, :deactivated, [])
      armed = CiLifecycle.pause_issue_for_ci_wait(state, issue)
      %{token: token} = armed.ci_lifecycle.rewakes[identifier]

      issue_fetcher = fn [^identifier] -> {:ok, [issue]} end

      next = CiLifecycle.handle_ci_wait_rewake(armed, identifier, token, issue_fetcher: issue_fetcher)

      sync_recorder(recorder)

      refute_received {:recorded, _position, _message}
      assert next.running[identifier].control.status == :deactivated
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)
    end

    test "tracker recording ignores unrelated process traffic" do
      recorder = start_recorder()

      assert {:error, :unscoped_test_call} =
               Task.async(fn -> RecordingGitHubClient.update_issue_state("42", "rework") end)
               |> Task.await()

      sync_recorder(recorder)
      refute_received {:recorded, _position, _message}
    end
  end
end

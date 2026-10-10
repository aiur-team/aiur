defmodule Aiur.Orchestrator.CiLifecycle.TransitionsTest do
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  alias Aiur.AgentQueueStore
  alias Aiur.CIApprovalStore
  alias Aiur.CiLifecycleTestSupport.RecordingGitHubClient
  alias Aiur.Orchestrator.CiLifecycle

  setup :ci_lifecycle_setup

  describe "CI lifecycle coordination" do
    test "a deactivated+ci-wait entry is woken by the CI terminal event" do
      identifier = unique_identifier("deactivated-terminal-wake")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      state = running_state(issue, recorder, :deactivated, paused_reason: :ci_wait)
      armed = CiLifecycle.pause_issue_for_ci_wait(state, issue)

      in_progress_issue = %{issue | state: "in-progress"}
      RecordingGitHubClient.return_issues([in_progress_issue])

      next = CiLifecycle.maybe_resume_for_ci_terminal(armed, identifier, :passed)

      assert next.running[identifier].issue.state == "in-progress"
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)
    end

    test "pending CI writes ci-wait and waits for live-runner pause evidence" do
      identifier = unique_identifier("ci-pending")
      recorder = start_recorder()

      issue = issue(identifier, "human-review")
      started_at = DateTime.add(DateTime.utc_now(), -30, :second)
      state = running_state(issue, recorder, :working, started_at: started_at)

      next = poll_ci(state, issue, %{decision: :pending, head_sha: "pending-head"})
      sync_recorder(recorder)

      assert_received {:recorded, 1, {:tracker_update, ^identifier, "ci-wait", [expected_state: "human-review"]}}
      assert_received {:recorded, 2, {:pause_agent, request_id, _generation}}
      assert is_integer(request_id)

      entry = Map.fetch!(next.running, identifier)

      assert entry.issue.state == "ci-wait"
      assert entry.control.status == :working
      assert entry.control.can_interrupt
      assert entry.pending_pause_reason == %{request_id: request_id, reason: :ci_wait}
      refute Map.has_key?(entry, :paused_reason)
      refute Map.has_key?(entry, :paused_at)
      assert entry.started_at == started_at
      assert MapSet.member?(next.claimed, identifier)
      assert Process.alive?(recorder)
      assert %{token: token, timer_ref: timer_ref} = next.ci_lifecycle.rewakes[identifier]
      assert is_reference(token)
      assert is_reference(timer_ref)
    end

    test "a failed tracker transition publishes nothing and leaves the runner untouched" do
      identifier = unique_identifier("ci-transition-failure")
      topic = "ticket.#{identifier}.ci.failed"
      recorder = start_recorder(topic)
      RecordingGitHubClient.return({:error, :tracker_down})

      issue = issue(identifier, "ci-wait")

      state =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      next =
        poll_ci(state, issue, %{
          decision: :failed,
          head_sha: "failed-head",
          pr_number: 941,
          failures: [%{name: "lint", result: "failure", excerpt: "failed"}]
        })

      sync_recorder(recorder)

      assert_received {:recorded, 1, {:tracker_update, ^identifier, "rework", [expected_state: "ci-wait"]}}
      refute_received {:recorded, 2, _message}

      # The OCC-5 CI/PR projection still caches even when the tracker write
      # itself fails and the transition is left untouched.
      assert next.running == state.running

      assert next.ci_lifecycle.poll_cache == %{
               identifier => %{
                 decision: :failed,
                 pr_number: 941,
                 head_sha: "failed-head",
                 draft?: false,
                 review_decision: nil
               }
             }

      assert next.ci_lifecycle.draft_stall_alerts == MapSet.new()

      assert Map.drop(next.ci_lifecycle, [:poll_cache, :parked_ready_alerts, :draft_stall_alerts]) ==
               Map.drop(state.ci_lifecycle, [:poll_cache, :parked_ready_alerts, :draft_stall_alerts])

      assert MapSet.member?(next.claimed, identifier)
    end

    test "terminal CI clears ci-wait on a ticket carrying contradictory state labels" do
      identifier = unique_identifier("ci-contradictory-failure")
      recorder = start_recorder("ticket.#{identifier}.ci.failed")

      # Two `agent:*` state labels make `extract_state` resolve to the real
      # disposition (rework, not the transient ci-wait). The lifecycle must not
      # let the pair strand the ticket: the terminal swap replaces the whole
      # label set, so exactly one state label survives (#2366).
      issue = %{issue(identifier, nil) | state_labels: ["ci-wait", "rework"]}

      state =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      next =
        poll_ci(state, issue, %{
          decision: :failed,
          head_sha: "failed-head",
          pr_number: 941,
          failures: [%{name: "lint", result: "failure", excerpt: "failed"}]
        })

      sync_recorder(recorder)

      # The transition resolves the contradictory pair to its real disposition
      # (`rework`) for the `expected_state` guard instead of passing `nil`
      # (which used to fail validation and skip the swap entirely).
      assert_received {:recorded, 1, {:tracker_update, ^identifier, "rework", [expected_state: "rework"]}}
      assert next.running[identifier].issue.state == "rework"
    end

    test "passing CI on a human-review + stale ci-wait pair keeps review and clears ci-wait" do
      identifier = unique_identifier("ci-contradictory-review")
      recorder = start_recorder()

      issue = %{issue(identifier, nil) | state_labels: ["ci-wait", "human-review"]}

      state =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> with_approved_head(identifier, "reviewed-head")
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      next =
        poll_ci(state, issue, %{
          decision: :passed,
          head_sha: "reviewed-head",
          pr_number: 941
        })

      sync_recorder(recorder)

      # The pair resolves to human-review, so the review disposition is kept and
      # the shared state owner reasserts review and clears ci-wait, leaving
      # exactly one state label (#2366).
      refute_received {:recorded, _position, {:tracker_update, ^identifier, "in-progress", _opts}}
      assert_received {:recorded, _position, {:tracker_update, ^identifier, "human-review", [expected_state: "human-review"]}}
      assert next.running[identifier].issue.state == "human-review"
    end

    test "a failed stale ci-wait removal leaves the ticket untouched and keeps the poll alive" do
      identifier = unique_identifier("ci-stale-remove-error")
      recorder = start_recorder()

      issue = %{issue(identifier, nil) | state_labels: ["ci-wait", "human-review"]}

      state =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> with_approved_head(identifier, "reviewed-head")
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      # The stale-label removal is best-effort: a transient GitHub failure must
      # not take down the poll loop. It logs and leaves the state untouched so
      # the next terminal observation retries (#2366).
      RecordingGitHubClient.return({:error, :github_down})

      next =
        poll_ci(state, issue, %{
          decision: :passed,
          head_sha: "reviewed-head",
          pr_number: 941
        })

      sync_recorder(recorder)

      # The poll completed without raising and the review disposition is
      # retained; no terminal transition happened.
      refute_received {:recorded, _position, {:tracker_update, ^identifier, "in-progress", _opts}}
      assert next.running[identifier].issue.state == "human-review"
    end

    test "passing CI records the head and publishes after the active-state write" do
      identifier = unique_identifier("ci-passed")
      topic = "ticket.#{identifier}.ci.passed"
      recorder = start_recorder(topic)

      issue = issue(identifier, "ci-wait")

      state =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)
        |> CiLifecycle.pause_issue_for_ci_wait(issue)

      next =
        poll_ci(state, issue, %{
          decision: :passed,
          head_sha: "approved-head",
          pr_number: 941
        })

      sync_recorder(recorder)

      assert_received {:recorded, 1, {:tracker_update, ^identifier, "in-progress", [expected_state: "ci-wait"]}}

      assert_received {:recorded, 2,
                       {:event,
                        %{
                          topic: ^topic,
                          source: :github,
                          head_sha: "approved-head",
                          pr_number: 941,
                          message: "CI passed for the current PR head"
                        }}}

      assert_received {:recorded, 3, {:agent_queue_updated, ^identifier, _item_id, false}}
      assert_received {:recorded, 4, {:resume_agent, _request_id, 101}}

      assert next.running[identifier].issue.state == "in-progress"
      assert next.running[identifier].control.status == :paused
      assert next.running[identifier].paused_reason == :ci_wait
      assert next.ci_lifecycle.approved_heads == %{identifier => "approved-head"}
      assert CIApprovalStore.load().approved_heads == %{identifier => "approved-head"}
      refute Map.has_key?(next.ci_lifecycle.rewakes, identifier)

      assert [%{body: %{events: [event]}}] = AgentQueueStore.list_pending(next.queue_store, identifier)
      assert event.topic == topic
      assert event.message == "CI passed for the current PR head"
    end

    test "a draft PR becoming ready publishes ready_for_review once for its current head" do
      identifier = unique_identifier("ready-for-review")
      topic = "ticket.#{identifier}.pr.ready_for_review"
      recorder = start_recorder(topic)
      issue = issue(identifier, "human-review")

      first = poll_ci(running_state(issue, recorder, :working, []), issue, %{decision: :passed, head_sha: "draft-head", pr_number: 941, draft?: true})
      sync_recorder(recorder)
      refute_received {:recorded, _position, {:event, %{topic: ^topic}}}

      next = poll_ci(first, issue, %{decision: :passed, head_sha: "ready-head", pr_number: 941, draft?: false})
      sync_recorder(recorder)

      assert_received {:recorded, _position, {:event, %{topic: ^topic, action: "ready_for_review", pr: %{"number" => 941, "draft" => false, "head" => %{"sha" => "ready-head"}}}}}

      _unchanged = poll_ci(next, issue, %{decision: :passed, head_sha: "ready-head", pr_number: 941, draft?: false})
      sync_recorder(recorder)
      refute_received {:recorded, _position, {:event, %{topic: ^topic}}}
    end

    # #2707: the CI poll saw the draft while the ticket sat in ci-wait. CI
    # passed and the ticket went back to in-progress, so the CI poll pruned its
    # cache entry. The agent then ran `gh pr ready` itself and moved the ticket
    # to human-review. The first CI poll after that must still see a
    # transition, whoever made it.
    test "a PR marked ready after its ticket left ci-wait publishes ready_for_review once" do
      identifier = unique_identifier("ready-after-ci-wait")
      topic = "ticket.#{identifier}.pr.ready_for_review"
      recorder = start_recorder(topic)
      ci_wait_issue = issue(identifier, "ci-wait")
      review_issue = issue(identifier, "human-review")

      state = poll_ci(running_state(ci_wait_issue, recorder, :working, []), ci_wait_issue, %{decision: :pending, head_sha: "draft-head", pr_number: 942, draft?: true})

      state =
        CiLifecycle.poll_github_ci(state,
          parked_ready_alert_loader: fn -> MapSet.new() end,
          draft_stall_alert_loader: fn -> MapSet.new() end,
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, []} end,
          ci_poller: fn _targets, _opts -> flunk("no ticket is in a CI poll state") end
        )

      refute Map.has_key?(state.ci_lifecycle.poll_cache, identifier)
      sync_recorder(recorder)
      refute_received {:recorded, _position, {:event, %{topic: ^topic}}}

      state = poll_ci(state, review_issue, %{decision: :passed, head_sha: "draft-head", pr_number: 942, draft?: false})
      sync_recorder(recorder)

      assert_received {:recorded, _position, {:event, %{topic: ^topic, action: "ready_for_review", pr: %{"number" => 942, "head" => %{"sha" => "draft-head"}}}}}
      refute_received {:recorded, _position, {:event, %{topic: ^topic}}}

      _state = poll_ci(state, review_issue, %{decision: :passed, head_sha: "draft-head", pr_number: 942, draft?: false})
      sync_recorder(recorder)
      refute_received {:recorded, _position, {:event, %{topic: ^topic}}}
    end

    test "alerts once when an approved, green PR is still a draft (#1974)" do
      identifier = unique_identifier("ci-draft-stall")
      alert_topic = "ticket.#{identifier}.pr.draft_approved_green"
      recorder = start_recorder(alert_topic)
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)
      issue = issue(identifier, "human-review")

      state =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)

      result = %{
        decision: :passed,
        head_sha: "stalled-head",
        pr_number: 941,
        draft?: true,
        review_decision: "APPROVED"
      }

      next = poll_ci(state, issue, result, alert_emitter: emitter)
      sync_recorder(recorder)

      # Approved + green + draft is always wrong: the daemon alerts so the
      # stall is loud instead of an indistinguishable BLOCKED.
      assert_received {:parked_alert, ^ref, ^alert_topic, alert_opts}
      assert Keyword.get(alert_opts, :needs_attention) == true

      # The projection records draft state so the Executor queue surfaces DRAFT.
      assert next.ci_lifecycle.poll_cache == %{
               identifier => %{
                 decision: :passed,
                 pr_number: 941,
                 head_sha: "stalled-head",
                 draft?: true,
                 review_decision: "APPROVED"
               }
             }

      assert MapSet.member?(next.ci_lifecycle.draft_stall_alerts, identifier)

      # Re-polling the identical stalled head must not re-alert every cycle.
      _again = poll_ci(next, issue, result, alert_emitter: emitter)
      sync_recorder(recorder)
      refute_received {:parked_alert, ^ref, ^alert_topic, _opts}
    end

    test "does not alert for a ready (non-draft) green PR" do
      identifier = unique_identifier("ci-draft-ready")
      alert_topic = "ticket.#{identifier}.pr.draft_approved_green"
      recorder = start_recorder(alert_topic)
      issue = issue(identifier, "human-review")

      state =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)

      _next =
        poll_ci(state, issue, %{
          decision: :passed,
          head_sha: "ready-head",
          pr_number: 942,
          draft?: false,
          review_decision: "APPROVED"
        })

      sync_recorder(recorder)
      refute_received {:recorded, _position, {:event, %{topic: ^alert_topic}}}
    end

    test "does not alert for an approved draft that is still pending CI" do
      identifier = unique_identifier("ci-draft-pending")
      alert_topic = "ticket.#{identifier}.pr.draft_approved_green"
      recorder = start_recorder(alert_topic)
      issue = issue(identifier, "ci-wait")

      state =
        issue
        |> running_state(recorder, :paused, paused_reason: :ci_wait)

      _next =
        poll_ci(state, issue, %{
          decision: :pending,
          head_sha: "pending-head",
          pr_number: 943,
          draft?: true,
          review_decision: "APPROVED"
        })

      sync_recorder(recorder)
      refute_received {:recorded, _position, {:event, %{topic: ^alert_topic}}}
    end
  end
end

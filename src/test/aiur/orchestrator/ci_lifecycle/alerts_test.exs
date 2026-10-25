defmodule Aiur.Orchestrator.CiLifecycle.AlertsTest do
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.PollCadence

  setup :ci_lifecycle_setup

  describe "parked-ready recovery alert" do
    defp parked_observation(overrides \\ %{}) do
      Map.merge(
        %{
          decision: :passed,
          pr_number: 77,
          head_sha: "1234567890abcdef1234567890abcdef12345678",
          draft?: false,
          review_decision: "APPROVED",
          mergeable: "MERGEABLE",
          merge_state_status: "BLOCKED",
          auto_merge_request: nil,
          merge_queue_entry: nil
        },
        overrides
      )
    end

    test "emits a needs-attention parked-ready alert for an approved ready mergeable unarmed PR" do
      identifier = unique_identifier("parked-ready-emit")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()

      next = poll_ci(state, issue, parked_observation(), alert_emitter: capture_alert_emitter(self(), ref))
      topic = "ticket.#{identifier}.pr.parked_ready"

      assert_received {:parked_alert, ^ref, ^topic, opts}
      assert Keyword.get(opts, :needs_attention) == true
      assert Keyword.get(opts, :central) == true
      assert Keyword.fetch!(opts, :message) =~ "`aiur pr merge 77 --reviewed-sha 1234567890abcdef1234567890abcdef12345678`"
      refute Keyword.fetch!(opts, :message) =~ "gh pr merge"
      assert MapSet.member?(next.ci_lifecycle.parked_ready_alerts, identifier)
    end

    test "does not re-emit for a still-parked PR already tracked" do
      identifier = unique_identifier("parked-ready-dedupe")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      first = poll_ci(state, issue, parked_observation(), alert_emitter: emitter)
      assert MapSet.member?(first.ci_lifecycle.parked_ready_alerts, identifier)
      # Past the :ci cadence gate, so dedupe (not the throttle) suppresses the re-emit.
      second = poll_ci(%{first | last_ci_poll_started_at_ms: nil}, issue, parked_observation(), alert_emitter: emitter)

      assert_received {:parked_alert, ^ref, _topic, _opts}
      refute_received {:parked_alert, ^ref, _topic, _opts}
      assert second.ci_lifecycle.parked_ready_alerts == first.ci_lifecycle.parked_ready_alerts
    end

    test "resolves the alert once the PR reports an auto-merge request" do
      identifier = unique_identifier("parked-ready-resolve")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)
      # A published :ci cadence would throttle the chained poll into a silent no-op (#3860).
      PollCadence.publish_effective_interval_ms(300_000, class: :ci)
      on_exit(&PollCadence.forget_effective_interval_ms/0)
      first = poll_ci(state, issue, parked_observation(), alert_emitter: emitter)
      assert MapSet.member?(first.ci_lifecycle.parked_ready_alerts, identifier)
      assert_received {:parked_alert, ^ref, _topic, _opts}
      armed = parked_observation(%{auto_merge_request: %{"enabledAt" => "2026-08-13T20:00:00Z"}})
      next = poll_ci(%{first | last_ci_poll_started_at_ms: nil}, issue, armed, alert_emitter: emitter)
      resolved_topic = "ticket.#{identifier}.pr.parked_ready.resolved"
      assert_received {:parked_alert, ^ref, ^resolved_topic, resolve_opts}
      assert Keyword.get(resolve_opts, :needs_attention) == false
      refute MapSet.member?(next.ci_lifecycle.parked_ready_alerts, identifier)
    end

    test "does not emit or clear on a transient poll failure" do
      identifier = unique_identifier("parked-ready-unknown")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()

      result = %{decision: :pending, pending_reason: :ci_lookup_unavailable, error: :test}
      next = poll_ci(state, issue, result, alert_emitter: capture_alert_emitter(self(), ref))

      refute_received {:parked_alert, ^ref, _topic, _opts}
      assert next.ci_lifecycle.parked_ready_alerts == MapSet.new()
    end

    test "resolves the alert when the open PR is no longer visible" do
      identifier = unique_identifier("parked-ready-gone")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      first = poll_ci(state, issue, parked_observation(), alert_emitter: emitter)
      assert MapSet.member?(first.ci_lifecycle.parked_ready_alerts, identifier)
      assert_received {:parked_alert, ^ref, _topic, _opts}

      gone = %{decision: :pending, pending_reason: :open_pr_not_yet_visible}
      next = poll_ci(first, issue, gone, alert_emitter: emitter)
      resolved_topic = "ticket.#{identifier}.pr.parked_ready.resolved"

      assert_receive {:parked_alert, ^ref, ^resolved_topic, _resolve_opts}, 100
      refute MapSet.member?(next.ci_lifecycle.parked_ready_alerts, identifier)
    end

    test "resolves the alert when the issue leaves the poll set" do
      identifier = unique_identifier("parked-ready-depart")
      issue = issue(identifier, "human-review")
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      state =
        running_state(issue, self(), :working, [])
        |> Map.update!(:ci_lifecycle, &Map.put(&1, :parked_ready_alerts, MapSet.new([identifier])))

      next =
        CiLifecycle.poll_github_ci(state,
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, []} end,
          alert_emitter: emitter,
          parked_ready_alert_loader: fn -> MapSet.new() end
        )

      resolved_topic = "ticket.#{identifier}.pr.parked_ready.resolved"

      assert_received {:parked_alert, ^ref, ^resolved_topic, _resolve_opts}
      refute MapSet.member?(next.ci_lifecycle.parked_ready_alerts, identifier)
    end
  end

  describe "approved green draft alert lifecycle" do
    defp draft_stall_observation(overrides \\ %{}) do
      Map.merge(
        %{
          decision: :passed,
          pr_number: 941,
          head_sha: "stalled-head",
          draft?: true,
          review_decision: "APPROVED"
        },
        overrides
      )
    end

    test "resolves the attention when the PR becomes ready" do
      identifier = unique_identifier("draft-stall-resolve")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      first = poll_ci(state, issue, draft_stall_observation(), alert_emitter: emitter)
      assert MapSet.member?(first.ci_lifecycle.draft_stall_alerts, identifier)
      assert_received {:parked_alert, ^ref, _topic, _opts}

      next = poll_ci(first, issue, draft_stall_observation(%{draft?: false}), alert_emitter: emitter)
      resolved_topic = "ticket.#{identifier}.pr.draft_approved_green.resolved"

      assert_received {:parked_alert, ^ref, ^resolved_topic, resolve_opts}
      assert Keyword.get(resolve_opts, :needs_attention) == false
      refute MapSet.member?(next.ci_lifecycle.draft_stall_alerts, identifier)
    end

    test "keeps the attention latched across an incomplete poll" do
      identifier = unique_identifier("draft-stall-transient")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      first = poll_ci(state, issue, draft_stall_observation(), alert_emitter: emitter)
      assert_received {:parked_alert, ^ref, _topic, _opts}

      transient = %{decision: :pending, pending_reason: :ci_lookup_unavailable, error: :test}
      second = poll_ci(first, issue, transient, alert_emitter: emitter)
      assert second.ci_lifecycle.poll_cache[identifier].draft? == true
      assert second.ci_lifecycle.poll_cache[identifier].review_decision == "APPROVED"

      third = poll_ci(second, issue, draft_stall_observation(), alert_emitter: emitter)

      refute_received {:parked_alert, ^ref, _topic, _opts}
      assert MapSet.member?(third.ci_lifecycle.draft_stall_alerts, identifier)
    end

    test "keeps the attention latched when REST fallback cannot observe approval" do
      identifier = unique_identifier("draft-stall-rest-fallback")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      first = poll_ci(state, issue, draft_stall_observation(), alert_emitter: emitter)
      assert_received {:parked_alert, ^ref, _topic, _opts}

      fallback = draft_stall_observation(%{review_decision: nil})
      next = poll_ci(first, issue, fallback, alert_emitter: emitter)

      refute_received {:parked_alert, ^ref, _topic, _opts}
      assert MapSet.member?(next.ci_lifecycle.draft_stall_alerts, identifier)
    end

    test "keeps the attention latched through a transient branch-list miss" do
      identifier = unique_identifier("draft-stall-not-visible")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      first = poll_ci(state, issue, draft_stall_observation(), alert_emitter: emitter)
      assert_received {:parked_alert, ^ref, _topic, _opts}

      transient = %{decision: :pending, pending_reason: :open_pr_not_yet_visible}
      next = poll_ci(first, issue, transient, alert_emitter: emitter)

      refute_received {:parked_alert, ^ref, _topic, _opts}
      assert MapSet.member?(next.ci_lifecycle.draft_stall_alerts, identifier)
    end

    test "resolves and clears the draft projection when a visible PR disappears" do
      identifier = unique_identifier("draft-stall-gone")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      first = poll_ci(state, issue, draft_stall_observation(), alert_emitter: emitter)
      assert_received {:parked_alert, ^ref, _topic, _opts}

      gone = %{decision: :pending, pending_reason: :open_pr_no_longer_visible}
      next = poll_ci(first, issue, gone, alert_emitter: emitter)
      resolved_topic = "ticket.#{identifier}.pr.draft_approved_green.resolved"

      assert_received {:parked_alert, ^ref, ^resolved_topic, _opts}
      refute MapSet.member?(next.ci_lifecycle.draft_stall_alerts, identifier)
      assert next.ci_lifecycle.poll_cache[identifier].draft? == false
      assert next.ci_lifecycle.poll_cache[identifier].review_decision == nil
    end

    test "keeps the attention active while the ticket temporarily leaves the poll set" do
      identifier = unique_identifier("draft-stall-depart")
      issue = issue(identifier, "human-review")
      ref = make_ref()
      emitter = capture_alert_emitter(self(), ref)

      state =
        running_state(issue, self(), :working, [])
        |> Map.update!(:ci_lifecycle, &Map.put(&1, :draft_stall_alerts, MapSet.new([identifier])))

      next =
        CiLifecycle.poll_github_ci(state,
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, []} end,
          alert_emitter: emitter,
          parked_ready_alert_loader: fn -> MapSet.new() end,
          draft_stall_alert_loader: fn -> MapSet.new() end
        )

      refute_received {:parked_alert, ^ref, _topic, _opts}
      assert MapSet.member?(next.ci_lifecycle.draft_stall_alerts, identifier)

      ready_issue = issue(identifier, "human-review")

      resolved =
        poll_ci(next, ready_issue, draft_stall_observation(%{draft?: false}), alert_emitter: emitter)

      resolved_topic = "ticket.#{identifier}.pr.draft_approved_green.resolved"
      assert_received {:parked_alert, ^ref, ^resolved_topic, _opts}
      refute MapSet.member?(resolved.ci_lifecycle.draft_stall_alerts, identifier)
    end

    test "seeds an active attention after restart instead of re-emitting it" do
      identifier = unique_identifier("draft-stall-restart")
      issue = issue(identifier, "human-review")
      state = running_state(issue, self(), :working, [])
      ref = make_ref()

      next =
        poll_ci(state, issue, draft_stall_observation(),
          alert_emitter: capture_alert_emitter(self(), ref),
          draft_stall_alert_loader: fn -> MapSet.new([identifier]) end
        )

      refute_received {:parked_alert, ^ref, _topic, _opts}
      assert MapSet.member?(next.ci_lifecycle.draft_stall_alerts, identifier)
    end
  end
end

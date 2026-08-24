defmodule Aiur.PerClassCadenceTest do
  # `PollCadence` publishes into `:persistent_term`, which is process-global, so
  # this module is deliberately not async.
  use Aiur.TestSupport

  alias Aiur.BuildOrder.Cadence
  alias Aiur.Orchestrator.{SnapshotStore, State, TrackerHealth}
  alias Aiur.PollCadence
  alias Aiur.Webhooks.ModeRegistry

  setup do
    PollCadence.forget_effective_interval_ms()
    on_exit(&PollCadence.forget_effective_interval_ms/0)
    :ok
  end

  describe "polling.intervals config resolution" do
    test "Config.poll_intervals/0 parses the per-class map" do
      write_workflow_file!(Workflow.workflow_file_path(),
        poll_interval_seconds: 120,
        polling_intervals: %{"dispatch" => 120, "planning" => 600, "review" => 300}
      )

      assert Config.poll_intervals() == %{dispatch: 120, planning: 600, review: 300}
    end

    # Acceptance: an unlisted class falls back to `polling.interval_seconds`, so
    # existing configs are unchanged in behaviour.
    test "an unlisted class falls back to interval_seconds" do
      write_workflow_file!(Workflow.workflow_file_path(),
        poll_interval_seconds: 120,
        polling_intervals: %{"planning" => 600}
      )

      assert PollCadence.base_interval_ms(class: :planning) == 600_000
      assert PollCadence.base_interval_ms(class: :dispatch) == 120_000
      assert PollCadence.base_interval_ms(class: :ci) == 120_000
      assert PollCadence.base_interval_ms(class: :review) == 120_000
      assert PollCadence.base_interval_ms(class: :firehose) == 120_000
    end

    # Review feedback #2309 (finding 1): `intervals.dispatch` was accepted,
    # documented and shipped but read by nothing — the dispatch tick's base
    # stayed `interval_seconds`. It now binds: the resolver honors the entry and
    # the scheduler's base is seeded from it, so `dispatch: 60` actually cuts the
    # tracker cadence instead of being a dead key.
    test "intervals.dispatch binds the dispatch tick" do
      write_workflow_file!(Workflow.workflow_file_path(),
        poll_interval_seconds: 120,
        polling_intervals: %{"dispatch" => 60}
      )

      assert PollCadence.base_interval_ms(class: :dispatch) == 60_000
      # An unlisted class is untouched by the dispatch override.
      assert PollCadence.base_interval_ms(class: :review) == 120_000

      # And the scheduler honors it: a state seeded from the dispatch class base
      # (which `Lifecycle.init/2` and `Lifecycle.refresh_runtime_config/1` now do)
      # schedules at 60s, not at the 120s scalar.
      state = %State{
        poll_interval_ms: PollCadence.base_interval_ms(class: :dispatch),
        github_poll_delays: %{},
        running: %{}
      }

      assert TrackerHealth.next_poll_delay_ms(state) == 60_000
    end
  end

  # The code owner's pinned config shape (#2309 comment) uses `0` for `planning`
  # and `firehose`: "0 means no timer — refresh on demand only. That is not a
  # placeholder." These tests pin that `0` is a first-class value end to end —
  # accepted by the schema, resolved to an on-demand cadence, published, shown in
  # status, and honoured by the Build Order catalog.
  describe "on-demand classes (interval 0 = no timer)" do
    test "Config.poll_intervals/0 keeps 0 as the on-demand value" do
      write_workflow_file!(Workflow.workflow_file_path(),
        poll_interval_seconds: 120,
        polling_intervals: %{"planning" => 0, "firehose" => 0}
      )

      assert Config.poll_intervals() == %{planning: 0, firehose: 0}
    end

    test "an explicitly-zero class resolves a 0 base, not the fallback" do
      write_workflow_file!(Workflow.workflow_file_path(),
        poll_interval_seconds: 120,
        polling_intervals: %{"planning" => 0}
      )

      assert PollCadence.base_interval_ms(class: :planning) == 0
      assert PollCadence.widest_configured_interval_ms(class: :planning) == 0
      # An unlisted class is untouched.
      assert PollCadence.base_interval_ms(class: :dispatch) == 120_000
      assert PollCadence.base_interval_ms(class: :review) == 120_000
    end

    test "an on-demand publish is read back as 0 and status shows it" do
      PollCadence.publish_effective_interval_ms(120_000, class: :dispatch)
      PollCadence.publish_effective_interval_ms(0, class: :planning)

      assert PollCadence.published_effective_interval_ms(class: :planning) == 0
      assert PollCadence.effective_interval_ms(class: :planning) == 0
      assert PollCadence.effective_intervals()[:planning] == 0
      assert PollCadence.effective_intervals()[:dispatch] == 120_000
    end

    test "an on-demand class never runs on the dispatch tick" do
      PollCadence.publish_effective_interval_ms(0, class: :planning)
      now = System.monotonic_time(:millisecond)

      # Even a loop that has never fired must not start on the tick — on-demand
      # means the demand, not the clock, starts it (#2309).
      assert PollCadence.within_class_cadence?(nil, now, :planning)
      assert PollCadence.within_class_cadence?(now - 1, now, :planning)
    end

    # Mutant #8 (review #2309): the `:dispatch -> :ok` zero-publish guard is the
    # whole `0 = on-demand` contract for the class that can never be on-demand. A
    # momentary "poll now" reschedule publishes `0`; it must leave the last real
    # dispatch cadence in force, never erase it (which would silently move every
    # dispatch-class threshold to the cold-start fallback for a tick).
    test "a 0 publish never erases the dispatch cadence" do
      PollCadence.publish_effective_interval_ms(120_000, class: :dispatch)
      PollCadence.publish_effective_interval_ms(0, class: :dispatch)

      assert PollCadence.published_effective_interval_ms(class: :dispatch) == 120_000
      assert PollCadence.effective_interval_ms(class: :dispatch) == 120_000
    end

    test "an un-named 0 publish leaves the dispatch cadence in force" do
      PollCadence.publish_effective_interval_ms(120_000, class: :dispatch)
      PollCadence.publish_effective_interval_ms(0)

      assert PollCadence.published_effective_interval_ms() == 120_000
      assert PollCadence.effective_interval_ms() == 120_000
    end

    # Acceptance: "a test that a per-class value reaches the right consumer."
    # With planning on-demand, the Build Order catalog must resolve a 0 cadence
    # (no timer) while the orchestrator snapshot keeps the dispatch cadence.
    test "the catalog resolves on-demand planning to no timer" do
      write_workflow_file!(Workflow.workflow_file_path(),
        poll_interval_seconds: 120,
        polling_intervals: %{"planning" => 0}
      )

      assert Cadence.effective().graph_catalog_refresh_ms == 0
      # The labels and ticket-detail values are display budgets, not timers, so
      # they stay positive even when the catalog itself is on-demand.
      assert Cadence.effective().graph_catalog_labels_refresh_ms > 0
      assert Cadence.effective().ticket_detail_freshness_ms > 0

      assert Aiur.Config.build_order_graph_projection_options()[:catalog_refresh_ms] == 0
      assert SnapshotStore.stale_age_ceiling_ms() > 0
    end
  end

  describe "per-class effective intervals" do
    test "a per-class publish is read back per class, never globally" do
      PollCadence.publish_effective_interval_ms(120_000, class: :dispatch)
      PollCadence.publish_effective_interval_ms(600_000, class: :planning)
      PollCadence.publish_effective_interval_ms(300_000, class: :review)

      assert PollCadence.effective_interval_ms(class: :dispatch) == 120_000
      assert PollCadence.effective_interval_ms(class: :planning) == 600_000
      assert PollCadence.effective_interval_ms(class: :review) == 300_000
    end

    test "an unpublished class inherits the dispatch value until it diverges" do
      PollCadence.publish_effective_interval_ms(120_000, class: :dispatch)

      assert PollCadence.published_effective_interval_ms(class: :ci) == 120_000
      assert PollCadence.effective_interval_ms(class: :ci) == 120_000
    end

    test "stale_after_ms derives from the named class" do
      PollCadence.publish_effective_interval_ms(120_000, class: :dispatch)
      PollCadence.publish_effective_interval_ms(600_000, class: :planning)

      assert PollCadence.stale_after_ms(2, class: :dispatch) == 240_000
      assert PollCadence.stale_after_ms(2, class: :planning) == 1_200_000
    end

    test "snapshot tolerance derives from the dispatch class" do
      PollCadence.publish_effective_interval_ms(120_000, class: :dispatch)
      PollCadence.publish_effective_interval_ms(600_000, class: :planning)

      assert PollCadence.snapshot_tolerance_ms(15_000, class: :dispatch) == 240_000
    end

    test "effective_intervals/0 reports every class" do
      PollCadence.publish_effective_interval_ms(120_000, class: :dispatch)
      PollCadence.publish_effective_interval_ms(600_000, class: :planning)

      intervals = PollCadence.effective_intervals()

      assert intervals[:dispatch] == 120_000
      assert intervals[:planning] == 600_000
      assert intervals[:review] == 120_000
      assert Map.keys(intervals) |> Enum.sort() == [:ci, :dispatch, :firehose, :planning, :review]
    end
  end

  # Acceptance: "a test that a per-class value reaches the right consumer." With
  # dispatch at 120s and planning at 600s published, the Build Order catalog —
  # a planning-class reader — must see 600s while the orchestrator snapshot —
  # a dispatch-class reader — must see the 120s cadence it rides on. A "bare
  # global interval" read would give both the same number, which is the failure
  # mode this ticket exists to kill.
  describe "per-class values reach the right consumer" do
    test "the catalog follows the planning class, the snapshot the dispatch class" do
      PollCadence.publish_effective_interval_ms(120_000, class: :dispatch)
      PollCadence.publish_effective_interval_ms(600_000, class: :planning)

      assert Cadence.effective().graph_catalog_refresh_ms == 600_000
      refute Cadence.effective().graph_catalog_refresh_ms == 120_000

      # 4 x 120s dispatch effective, floored at 120s.
      assert SnapshotStore.stale_age_ceiling_ms() == 480_000
      refute SnapshotStore.stale_age_ceiling_ms() == 2_400_000
    end
  end

  test "the schema's known poll classes stay in sync with PollCadence.poll_classes/0" do
    known = ["ci", "dispatch", "firehose", "planning", "review"]
    assert PollCadence.poll_classes() |> Enum.map(&Atom.to_string/1) |> Enum.sort() == known
  end

  # The loops that ride on the dispatch tick (comment poll, CI poll) throttle
  # themselves to their class cadence via `within_class_cadence?/3`. The four
  # limits are the whole contract: skip only when the class cadence is published
  # AND the loop has already run AND that cadence has not elapsed.
  describe "within_class_cadence?/3" do
    test "skips while within the published class cadence" do
      PollCadence.publish_effective_interval_ms(300_000, class: :review)
      now = System.monotonic_time(:millisecond)
      assert PollCadence.within_class_cadence?(now - 10_000, now, :review)
    end

    test "runs once the class cadence has elapsed" do
      PollCadence.publish_effective_interval_ms(300_000, class: :review)
      now = System.monotonic_time(:millisecond)
      refute PollCadence.within_class_cadence?(now - 300_001, now, :review)
    end

    test "never skips before the class cadence is published" do
      PollCadence.forget_effective_interval_ms()
      now = System.monotonic_time(:millisecond)
      refute PollCadence.within_class_cadence?(now - 1, now, :review)
    end

    test "never skips before the loop has ever run" do
      PollCadence.publish_effective_interval_ms(300_000, class: :review)
      now = System.monotonic_time(:millisecond)
      refute PollCadence.within_class_cadence?(nil, now, :review)
    end
  end

  # Mutant #7 (review #2309): `TrackerHealth.publish_poll_cadence/2` is the only
  # production path that publishes a per-class cadence in a running daemon, and
  # it had no test — the rest of this suite publishes every class by hand, so
  # deleting `publish_class_cadences/2` left it green. These tests drive the
  # production function and would fail if the per-class publish call vanished
  # (every un-published class would inherit the dispatch value instead of its
  # own).
  describe "TrackerHealth.publish_poll_cadence/2 production path" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(),
        poll_interval_seconds: 120,
        polling_intervals: %{"dispatch" => 120, "review" => 300, "planning" => 0}
      )

      # The default `ModeRegistry` is shared across this VM, and schedule /
      # publish assertions are exact values: a webhook-proven repo would apply
      # `webhooks.poll_widen_factor` (2.0) to every base, so force the test repo
      # back to plain polling before each case. This is what makes the suite
      # order-independent.
      if repo = Aiur.GitHub.Config.repo(), do: ModeRegistry.configure(repo, false)

      :ok
    end

    defp publish_schedule do
      state = %State{poll_interval_ms: 120_000, github_poll_delays: %{}}
      schedule = TrackerHealth.poll_schedule(state)
      :ok = TrackerHealth.publish_poll_cadence(state, schedule)
      state
    end

    test "publishes every class cadence from the configured intervals" do
      publish_schedule()

      assert PollCadence.published_effective_interval_ms(class: :dispatch) == 120_000
      # CI and firehose fall back to interval_seconds (no entry configured).
      assert PollCadence.published_effective_interval_ms(class: :ci) == 120_000
      assert PollCadence.published_effective_interval_ms(class: :firehose) == 120_000
      # Planning is on-demand.
      assert PollCadence.published_effective_interval_ms(class: :planning) == 0
    end

    # Review feedback finding 5: on a repo not proven webhook-backed, the
    # comment-poll safety net must keep the dispatch rate no matter what
    # `intervals.review` says — a wide `review` on a polling repo would be a
    # silent minutes-long floor on operator-comment wakes. The divergence is
    # enforced at publish time.
    test "review diverges only on a repo proven webhook-backed" do
      publish_schedule()

      # The test checkout's repo is not webhook-proven: review stays at dispatch.
      assert PollCadence.published_effective_interval_ms(class: :review) ==
               PollCadence.published_effective_interval_ms(class: :dispatch)

      # Prove the same repo webhook-backed: the configured review cadence binds.
      # The production path reads the default `ModeRegistry` (which is running),
      # so `record_delivery/2` — the exact call a webhook receiver makes — is
      # what promotes the repo.
      repo = Aiur.GitHub.Config.repo()
      assert is_binary(repo)

      :ok = Aiur.Webhooks.record_delivery(repo, at: ~U[2026-08-10 12:00:00Z])
      assert Aiur.Webhooks.webhook_backed?(repo)

      publish_schedule()

      review_ms = PollCadence.published_effective_interval_ms(class: :review)
      dispatch_ms = PollCadence.published_effective_interval_ms(class: :dispatch)
      assert review_ms > dispatch_ms
      assert review_ms == 600_000

      # Restore polling so this case does not leak webhook state into sibling
      # cases' exact-value assertions.
      ModeRegistry.configure(repo, false)
    end

    # Review feedback finding 4: `class_effective_ms/3` must compose the same
    # GitHub `X-Poll-Interval` / connectivity backoff floor the dispatch schedule
    # applies. Before #2309 every consumer read the single floored value, so a
    # class whose published cadence dropped the floor would read *narrower* than
    # the daemon actually polls while GitHub throttles us — a behaviour change on
    # a default config.
    test "class cadences compose the GitHub floor like the dispatch schedule" do
      write_workflow_file!(Workflow.workflow_file_path(),
        poll_interval_seconds: 120,
        polling_intervals: %{"planning" => 600}
      )

      state = %State{poll_interval_ms: 120_000, github_poll_delays: %{comments: 900_000}}
      schedule = TrackerHealth.poll_schedule(state)

      # The dispatch tick itself is floored.
      assert schedule.delay_ms == 900_000
      :ok = TrackerHealth.publish_poll_cadence(state, schedule)

      # Planning resolves to 600s but is floored by the 900s GitHub delay.
      assert PollCadence.published_effective_interval_ms(class: :dispatch) == 900_000
      assert PollCadence.published_effective_interval_ms(class: :planning) == 900_000
    end

    test "an on-demand class stays 0 even under a GitHub floor" do
      state = %State{poll_interval_ms: 120_000, github_poll_delays: %{comments: 900_000}}
      schedule = TrackerHealth.poll_schedule(state)
      :ok = TrackerHealth.publish_poll_cadence(state, schedule)

      assert PollCadence.published_effective_interval_ms(class: :planning) == 0
    end
  end

  # Acceptance: "a measurement before and after, using the same one-hour ledger
  # window, showing where the GraphQL points went." The #2309 ledger table
  # measured per-call GraphQL costs (CI 92/46 = 2, comment poll 77/14 = 5.5,
  # review threads 61/61 = 1, Build Order catalog 27/2 = 13.5). This is a
  # *projection* — arithmetic over those measured per-call costs against the
  # shipped `polling.intervals` example — not a live measurement: nothing here
  # observes real traffic or a rate-limit counter diff. It projects a one-hour
  # window before (every class at the dispatch cadence) and after (the cadences
  # the shipped example recommends), resolving the cadences through
  # `PollCadence.base_interval_ms/1` from the config map itself so the numbers
  # come from the shipped configuration, not hand-published constants. A live
  # one-hour ledger run against a real repository is the operator's operational
  # confirmation; this projection is the model the PR ships against.
  #
  # The figure is deliberately the *opt-in ceiling*: it is computed at the base
  # cadences, so the idle/webhook widen factors (which only lengthen intervals)
  # and the webhook-proof prerequisite on `review` can only push the real spend
  # below it. For any config that leaves `polling.intervals` unset — every
  # class falls back to `interval_seconds`, so no gate ever binds — the
  # merge-time delta is exactly zero.
  describe "one-hour GraphQL ledger projection (before/after)" do
    @hour_ms 3_600_000

    # Points per call, measured in the #2309 ledger table.
    @ci_points_per_call 2.0
    @review_points_per_call 5.5
    @review_threads_points_per_call 1.0
    @planning_points_per_call 13.5

    defp hourly_calls(0), do: 0
    defp hourly_calls(interval_ms), do: div(@hour_ms, interval_ms)

    test "the shipped recommended intervals move the one-hour GraphQL spend" do
      # The shipped example config (`.aiur/examples/config.example` and the
      # workflow templates): dispatch at the tracker cadence, review at 300s,
      # planning on-demand. CI is deliberately not listed, so it inherits
      # `interval_seconds` — CI stays demand-scoped at the dispatch tick.
      write_workflow_file!(Workflow.workflow_file_path(),
        poll_interval_seconds: 120,
        polling_intervals: %{"dispatch" => 120, "review" => 300, "planning" => 0}
      )

      dispatch = PollCadence.base_interval_ms(class: :dispatch)
      ci = PollCadence.base_interval_ms(class: :ci)
      review = PollCadence.base_interval_ms(class: :review)
      planning = PollCadence.base_interval_ms(class: :planning)

      assert {dispatch, ci, review, planning} == {120_000, 120_000, 300_000, 0}

      before =
        hourly_calls(dispatch) *
          (@ci_points_per_call + @review_points_per_call + @review_threads_points_per_call + @planning_points_per_call)

      after_spend =
        hourly_calls(ci) * @ci_points_per_call +
          hourly_calls(review) * (@review_points_per_call + @review_threads_points_per_call) +
          hourly_calls(planning) * @planning_points_per_call

      # Before: 660 points/hour. After (shipped example: review 300s, planning
      # on-demand): 138 points/hour — CI stays demand-scoped at the dispatch
      # tick, review halves, and the Build Order catalog (the most expensive
      # per-call query) stops running on a timer entirely. The `219` figure the
      # PR body once quoted was the `planning: 600` variant and is not shipped;
      # 138 is the number for the recommended config.
      assert before == 660
      assert after_spend == 138
      assert after_spend < before * 0.25
    end
  end
end

defmodule Aiur.PerClassCadenceTest do
  # `PollCadence` publishes into `:persistent_term`, which is process-global, so
  # this module is deliberately not async.
  use Aiur.TestSupport

  alias Aiur.BuildOrder.Cadence
  alias Aiur.Orchestrator.SnapshotStore
  alias Aiur.PollCadence

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

  # Acceptance: "a measurement before and after, using the same one-hour ledger
  # window, showing where the GraphQL points went." The #2309 ledger table
  # measured per-call GraphQL costs (CI 92/46 = 2, comment poll 77/14 = 5.5,
  # review threads 61/61 = 1, Build Order catalog 27/2 = 13.5). This projects a
  # one-hour window before (every class at the dispatch cadence) and after (the
  # proposed diverged cadences), resolving the cadences through
  # `PollCadence.effective_interval_ms/1` so the projection is pinned to the
  # code actually being shipped, not to arithmetic alone. A live one-hour ledger
  # run against a real repository is the operator's operational confirmation;
  # this is the model the PR ships against.
  describe "one-hour GraphQL ledger measurement (before/after)" do
    @hour_ms 3_600_000
    @dispatch_cadence_ms 120_000
    # CI stays at the dispatch cadence the loop rides on: demand-scoping (only
    # poll PRs with work in flight) is its cost control, not a wider interval.
    @ci_cadence_ms 120_000
    @review_cadence_ms 300_000
    @planning_cadence_ms 600_000

    # Points per call, measured in the #2309 ledger table.
    @ci_points_per_call 2.0
    @review_points_per_call 5.5
    @review_threads_points_per_call 1.0
    @planning_points_per_call 13.5

    defp hourly_calls(interval_ms), do: div(@hour_ms, interval_ms)

    test "diverging review and planning moves the one-hour GraphQL spend" do
      PollCadence.publish_effective_interval_ms(@dispatch_cadence_ms, class: :dispatch)
      PollCadence.publish_effective_interval_ms(@ci_cadence_ms, class: :ci)
      PollCadence.publish_effective_interval_ms(@review_cadence_ms, class: :review)
      PollCadence.publish_effective_interval_ms(@planning_cadence_ms, class: :planning)

      before =
        @dispatch_cadence_ms
        |> hourly_calls()
        |> Kernel.*(@ci_points_per_call + @review_points_per_call + @review_threads_points_per_call + @planning_points_per_call)

      after_spend =
        hourly_calls(PollCadence.effective_interval_ms(class: :ci)) * @ci_points_per_call +
          hourly_calls(PollCadence.effective_interval_ms(class: :review)) *
            (@review_points_per_call + @review_threads_points_per_call) +
          hourly_calls(PollCadence.effective_interval_ms(class: :planning)) * @planning_points_per_call

      # Before: 660 points/hour. After: 219 points/hour — the three GraphQL
      # pollers drop by roughly two thirds once review and planning stop running
      # at the dispatch rate, which is the whole point of the ticket.
      assert before == 660
      assert after_spend == 219
      assert after_spend < before * 0.4
    end
  end
end

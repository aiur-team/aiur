defmodule Aiur.CurrentRunSummary.ProjectionTest do
  use ExUnit.Case, async: true

  alias Aiur.{CurrentRunSummary, TrackerIdentity}
  alias Aiur.CurrentRunSummary.Projection

  test "projects exact weighted progress and excludes non-work terminals" do
    rows = [
      row(1, lifecycle: :completed, terminal?: true, complexity: 2),
      row(2,
        lifecycle: :running,
        complexity: 3,
        progress: %{status: :known, percent: 40, freshness: :fresh},
        runtime: %{bucket: :running, work_state: :working}
      ),
      row(3, lifecycle: :queued, complexity: nil, progress: %{status: :unknown}),
      row(4,
        lifecycle: :cancelled,
        terminal?: true,
        complexity: 5,
        tracker_state: "Not Planned"
      )
    ]

    snapshot = CurrentRunSummary.project(%{run: run(), units: units(rows)})

    assert snapshot.version == 1
    assert snapshot.health == %{status: :healthy, reasons: []}
    assert snapshot.freshness.status == :fresh

    assert snapshot.counts == %{
             live: 1,
             remaining: 2,
             successful_terminal: 1,
             non_work_terminal: 1,
             unknown_state: 0,
             total: 4
           }

    assert snapshot.weights == %{
             eligible: 6,
             successful_terminal: 2,
             remaining: 4,
             excluded: 5,
             excluded_count: 1,
             defaulted: 1,
             defaulted_count: 1,
             known_progress: 6,
             unknown_progress: 0
           }

    assert snapshot.progress.weighted_numerator == %{value: 320, scale: 100}
    assert snapshot.progress.lower_bound == %{numerator: 8, denominator: 15}
    assert snapshot.progress.coverage == %{numerator: 1, denominator: 1}
    assert snapshot.progress.exact == %{numerator: 8, denominator: 15}
    assert snapshot.eta.reason == :insufficient_successful_completions
  end

  test "computes ETA only from sufficient completed-weight evidence" do
    rows = [
      row(1, lifecycle: :completed, terminal?: true, complexity: 2),
      row(2, lifecycle: :completed, terminal?: true, complexity: 3),
      row(3,
        lifecycle: :running,
        complexity: 5,
        progress: %{status: :known, percent: 20, freshness: :fresh},
        runtime: %{bucket: :running, work_state: :working}
      )
    ]

    snapshot =
      CurrentRunSummary.project(%{
        run: run(elapsed_ms: 1_200_000),
        units: units(rows),
        denominator_generation: 4
      })

    assert snapshot.eta.status == :available
    assert snapshot.eta.confidence == :evidence_based
    assert snapshot.eta.denominator_generation == 4
    assert snapshot.eta.sample_count == 2
    assert snapshot.eta.completed_weight == 5
    assert snapshot.eta.remaining_weight == 5
    assert snapshot.eta.throughput_weight_per_second == %{numerator: 1, denominator: 240}
    assert snapshot.eta.duration_seconds == %{numerator: 1_200, denominator: 1}
  end

  test "stale or missing member progress is unknown instead of inferred" do
    rows = [
      row(1,
        lifecycle: :running,
        complexity: 2,
        progress: %{status: :known, percent: 90, freshness: :stale},
        runtime: %{bucket: :running, work_state: :working}
      ),
      row(2, lifecycle: :running, complexity: 3, progress: nil, runtime: %{bucket: :running})
    ]

    snapshot = CurrentRunSummary.project(%{run: run(), units: units(rows)})

    assert snapshot.progress.exact == nil
    assert snapshot.progress.lower_bound == %{numerator: 0, denominator: 1}
    assert snapshot.progress.coverage == %{numerator: 0, denominator: 1}
    assert snapshot.progress.unknown_weight == 5
    assert snapshot.freshness.status == :stale
  end

  test "an explicit invalid run flag cannot be masked by cached run fields" do
    snapshot =
      CurrentRunSummary.project(%{
        run: Map.put(run(), :valid?, false),
        units: units([row(1, lifecycle: :completed, terminal?: true, complexity: 2)])
      })

    refute snapshot.run.valid?
    assert snapshot.health.status == :unavailable
    assert :invalid_run_window in snapshot.health.reasons
    assert snapshot.progress.exact == nil
    assert snapshot.eta.reason == :invalid_run_window
  end

  test "membership reconciliation freshness gates exact progress and ETA" do
    rows = [
      row(1, lifecycle: :completed, terminal?: true, complexity: 2),
      row(2, lifecycle: :completed, terminal?: true, complexity: 3)
    ]

    snapshot =
      CurrentRunSummary.project(%{
        run: run(),
        units: units(rows, membership_freshness: %{status: :unknown})
      })

    assert snapshot.health.status == :partial
    assert :membership_not_fresh in snapshot.health.reasons
    assert snapshot.freshness.status == :unknown
    assert snapshot.sources.membership_freshness == :unknown
    assert snapshot.progress.exact == nil
    assert snapshot.eta.reason == :membership_not_fresh
  end

  test "unhealthy complexity evidence gates exact progress and ETA" do
    rows = [
      row(1, lifecycle: :completed, terminal?: true, complexity: 2),
      row(2, lifecycle: :completed, terminal?: true, complexity: 3),
      row(3, lifecycle: :running, complexity: 5)
    ]

    snapshot =
      CurrentRunSummary.project(%{
        run: run(),
        units: units(rows),
        weight_health: :unavailable
      })

    assert snapshot.health.status == :partial
    assert :unhealthy_weight_facts in snapshot.health.reasons
    assert snapshot.freshness.status == :stale
    assert snapshot.progress.exact == nil
    assert snapshot.eta.reason == :unhealthy_weight_facts
  end

  test "malformed optional source containers degrade deterministically without raising" do
    snapshot =
      CurrentRunSummary.project(%{
        run: run(),
        units: %{rows: nil, health: nil, freshness: nil}
      })

    assert snapshot.counts.total == 0
    assert snapshot.health.status == :partial
    assert snapshot.freshness.status == :unknown
    assert snapshot.progress.exact == nil
  end

  test "denominator signatures are deterministic and track weight boundaries" do
    rows = [row(1, complexity: 2), row(2, complexity: 3)]

    assert Projection.denominator_signature(rows) ==
             Projection.denominator_signature(Enum.reverse(rows))

    refute Projection.denominator_signature(rows) ==
             Projection.denominator_signature([row(1, complexity: 2), row(2, complexity: 4)])

    refute Projection.denominator_signature(rows) ==
             Projection.denominator_signature([
               row(1, complexity: 2),
               row(2, complexity: 3, lifecycle: :cancelled, terminal?: true)
             ])
  end

  defp run(opts \\ []) do
    %{
      id: "run-1",
      started_at: ~U[2026-07-17 10:00:00Z],
      observed_at: ~U[2026-07-17 10:20:00Z],
      elapsed_ms: Keyword.get(opts, :elapsed_ms, 1_200_000)
    }
  end

  defp units(rows, opts \\ []) do
    membership_freshness = Keyword.get(opts, :membership_freshness, %{status: :fresh})

    %{
      generation: %{membership: 4, status: 5, activity: 6, issue: 7},
      health: %{
        membership: :healthy,
        status: :available,
        activity: :available,
        issue: :available
      },
      freshness: %{
        membership: membership_freshness,
        status: :fresh,
        activity: :fresh,
        issue: :fresh
      },
      truncated?: false,
      rows: rows
    }
  end

  defp row(number, attrs) do
    %{
      identity: identity(number),
      lifecycle: Keyword.get(attrs, :lifecycle, :running),
      terminal?: Keyword.get(attrs, :terminal?, false),
      replacement_boundary?: Keyword.get(attrs, :replacement_boundary?, false),
      tracker_state: Keyword.get(attrs, :tracker_state, "in-progress"),
      complexity: Keyword.get(attrs, :complexity, 1),
      progress: Keyword.get(attrs, :progress, %{status: :known, percent: 0, freshness: :fresh}),
      runtime: Keyword.get(attrs, :runtime, %{bucket: :idle})
    }
  end

  defp identity(number) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "NODE-#{number}",
      identifier: Integer.to_string(number),
      reason: nil
    }
  end
end

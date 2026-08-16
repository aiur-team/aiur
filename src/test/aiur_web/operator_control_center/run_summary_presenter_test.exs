defmodule AiurWeb.OperatorControlCenter.RunSummaryPresenterTest do
  use ExUnit.Case, async: true

  alias Aiur.{CurrentRunSummary, TrackerIdentity}
  alias AiurWeb.OperatorControlCenter.RunSummaryPresenter, as: Presenter

  describe "present/2 counts and progress" do
    test "exact weighted progress is a ready view with aria-ready percent" do
      snapshot =
        project([
          row(1, lifecycle: :completed, terminal?: true, complexity: 1),
          row(2, complexity: 1, progress: known(100))
        ])

      view = Presenter.present(snapshot)

      assert view.state == :ready
      assert view.progress.kind == :exact
      assert view.progress.percent == 100
      assert view.counts.successful_terminal == 1
      assert view.counts.total == 2
      assert view.health.status == :healthy
      assert view.freshness.status == :fresh
    end

    test "unknown member progress yields a lower bound with named coverage, never an exact percent" do
      snapshot =
        project([
          row(1, complexity: 1, progress: known(50)),
          row(2, complexity: 1, progress: %{status: :unknown})
        ])

      view = Presenter.present(snapshot)

      assert view.progress.kind == :lower_bound
      assert view.progress.percent == nil
      assert is_integer(view.progress.lower_bound_percent)
      assert is_integer(view.progress.coverage_percent)
      assert view.progress.unknown_weight > 0
    end

    test "partial current-fact progress carries one shared set of operator labels" do
      snapshot =
        project([row(1, complexity: 1, progress: known(40))])
        |> put_in([:progress, :exact], nil)
        |> put_in([:progress, :current_facts], %{
          status: :settling,
          value: %{numerator: 2, denominator: 5},
          lower_bound?: false,
          current_member_count: 1,
          total_member_count: 2,
          missing_member_count: 1
        })

      view = Presenter.present(snapshot)

      assert view.progress.kind == :partial
      assert view.progress.display_percent_label == "40%"
      assert view.progress.current_members_label == "1 of 2 members current"
      assert view.progress.fact_status_label == "Still settling"
      assert view.progress.fact_status_detail == "progress inputs are still settling"
    end

    test "partial current-fact progress qualifies an unknown subset as a lower bound" do
      snapshot =
        project([row(1, complexity: 1, progress: known(40))])
        |> put_in([:progress, :exact], nil)
        |> put_in([:progress, :current_facts], %{
          status: :settling,
          value: %{numerator: 2, denominator: 5},
          lower_bound?: true,
          current_member_count: 1,
          total_member_count: 2,
          missing_member_count: 1
        })

      view = Presenter.present(snapshot)

      assert view.progress.kind == :partial
      assert view.progress.partial_lower_bound?
      assert view.progress.display_percent_label == "At least 40%"
      assert Presenter.announcement(view) =~ "Progress at least 40 percent"
    end

    test "zero eligible weight names the absence of weighted progress" do
      snapshot =
        project([
          row(1, lifecycle: :cancelled, terminal?: true, complexity: 3, tracker_state: "Not Planned")
        ])

      view = Presenter.present(snapshot)

      assert view.progress.kind == :none
      assert view.progress.excluded_count == 1
      assert view.eta.status == :unavailable
      assert view.eta.reason == :zero_eligible_weight
    end

    test "defaulted weight is surfaced distinctly from known weight" do
      snapshot = project([row(1, complexity: nil, progress: known(0))])

      view = Presenter.present(snapshot)

      assert view.progress.defaulted_count == 1
      assert view.progress.defaulted_weight == 1
    end
  end

  describe "present/2 elapsed and ETA" do
    test "available ETA formats a remaining duration with formula and confidence" do
      snapshot =
        project(
          [
            row(1, lifecycle: :completed, terminal?: true, complexity: 2),
            row(2, lifecycle: :completed, terminal?: true, complexity: 3),
            row(3, complexity: 2, progress: known(50))
          ],
          elapsed_ms: 1_200_000
        )

      view = Presenter.present(snapshot)

      assert view.elapsed.label == "20m"
      assert view.eta.status == :available
      assert view.eta.confidence == :evidence_based
      assert view.eta.formula_version == "completed_weight_rate_v1"
      assert view.eta.sample_count == 2
      assert view.eta.label =~ "remaining"
    end

    test "insufficient completions produces a named unavailable ETA reason" do
      snapshot =
        project([
          row(1, lifecycle: :completed, terminal?: true, complexity: 2),
          row(2, complexity: 2, progress: known(40))
        ])

      view = Presenter.present(snapshot)

      assert view.eta.status == :unavailable
      assert view.eta.reason == :insufficient_successful_completions
      assert view.eta.label =~ "two completions"
    end
  end

  describe "present/2 states" do
    test "loading when no snapshot has been read" do
      assert Presenter.present(nil).state == :loading
    end

    test "empty when there is no valid run and no units" do
      snapshot = CurrentRunSummary.project(%{run: %{}, units: units([])})
      view = Presenter.present(snapshot)

      assert view.state == :empty
      assert view.health.status == :unavailable
    end

    test "unavailable when membership source is unavailable but units exist" do
      snapshot =
        CurrentRunSummary.project(%{
          run: run(),
          units: units([row(1, complexity: 1, progress: known(0))], health: unavailable_membership())
        })

      view = Presenter.present(snapshot)

      assert view.state == :unavailable
      assert :unhealthy_membership in view.health.reasons
    end
  end

  describe "reconcile/2 last-known-good retention" do
    test "adopts an available incoming snapshot" do
      current = healthy_snapshot()
      incoming = healthy_snapshot()

      assert {^incoming, false} = Presenter.reconcile(current, incoming)
    end

    test "retains a healthy same-run snapshot when the update is unavailable" do
      current = healthy_snapshot()
      incoming = unavailable_snapshot(run_id: "run-1")

      assert {^current, true} = Presenter.reconcile(current, incoming)
      assert Presenter.present(current, true).state == :stale
    end

    test "shows the unavailable snapshot for a new run generation" do
      current = healthy_snapshot()
      incoming = unavailable_snapshot(run_id: "run-2")

      assert {^incoming, false} = Presenter.reconcile(current, incoming)
    end

    test "does not retain when the incoming run window is unconfirmable" do
      current = healthy_snapshot()
      incoming = unavailable_snapshot(run_id: nil)

      assert {^incoming, false} = Presenter.reconcile(current, incoming)
    end

    test "adopts the first snapshot when nothing is displayed yet" do
      incoming = unavailable_snapshot(run_id: "run-1")
      assert {^incoming, false} = Presenter.reconcile(nil, incoming)
    end
  end

  describe "announcement/1" do
    test "is a single bounded sentence per state" do
      assert Presenter.announcement(%{state: :loading}) =~ "Loading"
      assert Presenter.announcement(%{state: :empty}) =~ "No active"

      ready = Presenter.present(project([row(1, complexity: 1, progress: known(100))]))
      announcement = Presenter.announcement(ready)

      assert announcement =~ "Current run"
      assert announcement =~ "Health"
      refute announcement =~ "\n"
    end
  end

  # --- fixtures ------------------------------------------------------------

  defp project(rows, opts \\ []) do
    CurrentRunSummary.project(%{run: run(opts), units: units(rows)})
  end

  defp healthy_snapshot, do: project([row(1, complexity: 1, progress: known(100))])

  defp unavailable_snapshot(opts) do
    %{
      version: 1,
      generation: 0,
      run: %{id: Keyword.get(opts, :run_id), valid?: false, elapsed_wall_seconds: nil},
      counts: %{live: 0, remaining: 0, successful_terminal: 0, non_work_terminal: 0, unknown_state: 0, total: 3},
      weights: %{eligible: 0, excluded: 0, excluded_count: 0, defaulted: 0, defaulted_count: 0},
      progress: %{denominator_weight: 0, known_weight: 0, unknown_weight: 0},
      eta: %{status: :unavailable, reason: :invalid_run_window},
      health: %{status: :unavailable, reasons: [:invalid_run_window]},
      freshness: %{status: :unavailable}
    }
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
    %{
      generation: %{membership: 4, status: 5, activity: 6, issue: 7},
      health: Keyword.get(opts, :health, healthy_sources()),
      freshness: %{membership: %{status: :fresh}, status: :fresh, activity: :fresh, issue: :fresh},
      truncated?: false,
      rows: rows
    }
  end

  defp healthy_sources, do: %{membership: :healthy, status: :available, activity: :available, issue: :available}

  defp unavailable_membership,
    do: %{membership: :unavailable, status: :available, activity: :available, issue: :available}

  defp known(percent), do: %{status: :known, percent: percent, freshness: :fresh}

  defp row(number, attrs) do
    %{
      identity: identity(number),
      lifecycle: Keyword.get(attrs, :lifecycle, :running),
      terminal?: Keyword.get(attrs, :terminal?, false),
      replacement_boundary?: Keyword.get(attrs, :replacement_boundary?, false),
      tracker_state: Keyword.get(attrs, :tracker_state, "in-progress"),
      complexity: Keyword.get(attrs, :complexity, 1),
      progress: Keyword.get(attrs, :progress, known(0)),
      runtime: Keyword.get(attrs, :runtime, %{bucket: :running, work_state: :working})
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

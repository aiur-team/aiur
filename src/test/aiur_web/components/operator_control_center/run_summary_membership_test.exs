defmodule AiurWeb.OperatorControlCenter.RunSummaryMembershipTest do
  use ExUnit.Case, async: true

  alias Aiur.CurrentRunSummary
  alias AiurWeb.OperatorControlCenter.RunSummaryPresenter

  @now ~U[2026-10-09 19:38:00Z]

  for freshness <- [:stale, :unknown, :partial], weight_health <- [:healthy, :stale] do
    test "#{freshness} membership with #{weight_health} weights hides progress percentages and fill" do
      snapshot = snapshot(unquote(freshness), unquote(weight_health))
      view = RunSummaryPresenter.present(snapshot)

      assert snapshot.eta.reason == :membership_not_fresh
      assert snapshot.counts.remaining == 472
      assert snapshot.progress.lower_bound == %{numerator: 1, denominator: 1}
      assert snapshot.progress.current_facts.value == %{numerator: 1, denominator: 1}
      assert view.progress.kind == :lower_bound
      assert view.progress.percent == nil
      assert view.progress.lower_bound_percent == nil
      assert view.progress.coverage_percent == nil
      assert RunSummaryPresenter.announcement(view) =~ "Progress coverage unknown"
    end
  end

  test "future regression guard: fresh membership preserves measured progress while tickets await completion" do
    view = :fresh |> snapshot(:healthy) |> RunSummaryPresenter.present()

    assert view.progress.kind == :exact
    assert view.progress.percent == 100
    assert view.counts.remaining == 472
  end

  test "a retained exact summary hides progress when the incoming membership is not fresh" do
    current = snapshot(:fresh, :healthy)
    incoming = snapshot(:stale, :healthy) |> put_in([:health, :status], :unavailable)
    assert {^current, true} = RunSummaryPresenter.reconcile(current, incoming)

    view = RunSummaryPresenter.present(current, true, incoming)
    assert view.state == :stale
    assert view.progress.percent == nil
    assert view.progress.lower_bound_percent == nil
    assert RunSummaryPresenter.announcement(view) =~ "Progress coverage unknown"
  end

  defp snapshot(freshness, weight_health) do
    row = %{
      lifecycle: :running,
      terminal?: false,
      complexity: 1,
      progress: %{status: :known, percent: 100, freshness: :fresh},
      runtime: %{bucket: :running, work_state: :working}
    }

    CurrentRunSummary.project(%{
      run: %{id: "run-3836", started_at: ~U[2026-10-09 19:15:00Z], observed_at: @now, elapsed_ms: 1_380_000},
      units: %{
        rows: List.duplicate(row, 472),
        health: %{membership: :healthy, status: :available, activity: :available, issue: :available},
        freshness: %{membership: %{status: freshness}, status: :fresh, activity: :fresh, issue: :fresh}
      },
      weight_health: weight_health
    })
  end
end

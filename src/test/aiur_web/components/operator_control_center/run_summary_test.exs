defmodule AiurWeb.OperatorControlCenter.RunSummaryTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.RunSummary

  @protected ["cost", "token", "provider", "quota", "credit", "plan", "tier", "$"]

  test "exact progress renders a determinate progressbar with aria-valuenow and named counts" do
    html = render(ready_view())

    assert html =~ ~s(role="progressbar")
    assert html =~ ~s(aria-valuenow="60")
    assert html =~ "60% complete (exact)"
    assert html =~ "Health: Healthy"
    assert html =~ "Fresh"
    assert html =~ "Live"
    assert html =~ "Succeeded"
    assert html =~ "Non-work terminal"
    assert html =~ ~s(role="status")
    assert html =~ "3 live"
    refute_protected(html)
  end

  test "lower-bound progress omits aria-valuenow and names coverage" do
    view =
      put_progress(ready_view(), %{
        kind: :lower_bound,
        percent: nil,
        lower_bound_percent: 45,
        coverage_percent: 70,
        denominator_weight: 10,
        known_weight: 7,
        unknown_weight: 3,
        excluded_weight: 0,
        excluded_count: 0,
        defaulted_weight: 0,
        defaulted_count: 0
      })

    html = render(view)

    refute html =~ "aria-valuenow"
    refute html =~ ~s(role="progressbar")
    assert html =~ "At least 45% complete (lower bound)"
    assert html =~ "70% of eligible weight measured."
  end

  test "zero eligible weight names the absence of weighted progress" do
    view = put_progress(ready_view(), %{ready_view().progress | kind: :none})
    html = render(view)

    assert html =~ "zero eligible weight"
  end

  test "stale view shows a last-known-good banner and still renders the facts grid" do
    view = %{ready_view() | state: :stale, retained?: true, freshness: %{status: :stale, label: "Stale"}}
    html = render(view)

    assert html =~ "Stale summary"
    assert html =~ "last known-good"
    assert html =~ "run-summary-grid"
  end

  test "unavailable view is an alert naming the health reasons" do
    view = %{
      ready_view()
      | state: :unavailable,
        health: %{status: :unavailable, reasons: [:unhealthy_membership], label: "Unavailable"}
    }

    html = render(view)

    assert html =~ ~s(role="alert")
    assert html =~ "unhealthy membership"
    refute html =~ "run-summary-grid"
  end

  test "empty and loading views render placeholders without a facts grid" do
    assert render(%{ready_view() | state: :empty}) =~ "No active Aiur run"
    assert render(%{state: :loading, retained?: false}) =~ "Loading current-run summary"
  end

  # --- helpers -------------------------------------------------------------

  defp render(view) do
    render_component(&RunSummary.run_summary/1, %{view: view, announcement: announcement(view)})
  end

  defp announcement(%{state: :loading}), do: "Loading the current-run summary."
  defp announcement(_view), do: "Current run. 3 live, 2 remaining, 1 succeeded of 6."

  defp put_progress(view, progress), do: %{view | progress: progress}

  defp ready_view do
    %{
      state: :ready,
      retained?: false,
      generation: 3,
      run_id: "run-1",
      counts: %{live: 3, remaining: 2, successful_terminal: 1, non_work_terminal: 1, unknown_state: 0, total: 6},
      progress: %{
        kind: :exact,
        percent: 60,
        lower_bound_percent: 60,
        coverage_percent: 100,
        denominator_weight: 10,
        known_weight: 10,
        unknown_weight: 0,
        excluded_weight: 2,
        excluded_count: 1,
        defaulted_weight: 0,
        defaulted_count: 0
      },
      elapsed: %{seconds: 1200, label: "20m"},
      eta: %{
        status: :available,
        duration_seconds: 480,
        label: "About 8m remaining",
        formula_version: "completed_weight_rate_v1",
        confidence: :evidence_based,
        sample_count: 2,
        reason: nil
      },
      health: %{status: :healthy, reasons: [], label: "Healthy"},
      freshness: %{status: :fresh, label: "Fresh"}
    }
  end

  defp refute_protected(html) do
    downcased = String.downcase(html)

    for term <- @protected do
      refute String.contains?(downcased, term), "expected no protected term #{inspect(term)} in run summary"
    end
  end
end

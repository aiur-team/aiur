defmodule Aiur.Experiments.Packs.DeliverySpeed do
  @moduledoc "Built-in ticket delivery metrics, with explicit capture and source coverage."
  @behaviour Aiur.Experiments.MetricPack
  alias Aiur.Experiments.{Coverage, Metric}
  alias Aiur.Experiments.Packs.DeliverySpeed.{Periods, TelemetrySource, Tickets}
  alias Aiur.Experiments.Sources.Common

  @definitions [
    {"flow", "start_to_pr_open", "duration", "ms", ["pr_opened_source_time"]},
    {"flow", "pr_open_to_merge", "duration", "ms", ["pr_opened_source_time"]},
    {"flow", "start_to_merge", "duration", "ms", []},
    {"flow", "blocker_merge_to_dependent_start", "duration", "ms", ["blocked_by"]},
    {"flow", "gap_between_prs", "duration", "ms", ["epic"]},
    {"review", "pr_ready_to_first_review", "duration", "ms", ["pr_opened_source_time", "review_source"]},
    {"review", "review_rounds", "count", "rounds", []},
    {"review", "rework_time", "duration", "ms", []},
    {"review", "ci_wait", "duration", "ms", ["ci_wait"]},
    {"throughput", "merged_per_hour", "bucketed", "tickets/hour", ["fleet_activity"]},
    {"throughput", "agents_vs_cap", "bucketed", "ratio", ["fleet_capacity"]},
    {"throughput", "idle_slot_hours", "bucketed", "slot-hours", ["ready_queue_depth"]},
    {"throughput", "binding_gate", "rate", "share", ["gate_reason"]},
    {"cost_quality", "spend_per_merged_ticket", "count", "USD", ["accounting"]},
    {"cost_quality", "tokens_per_merged_ticket", "count", "tokens", ["accounting"]},
    {"cost_quality", "main_red_events", "bucketed", "events/day", ["main_red"]},
    {"cost_quality", "reverts", "bucketed", "reverts/day", ["reverts"]},
    {"ci_stability", "ci_run_failure_rate", "binary", "runs", ["ci_runs"]},
    {"ci_stability", "ci_rerun_rate", "binary", "runs", ["ci_runs"]},
    {"ci_stability", "merge_group_failure_rate", "binary", "runs", ["ci_runs"]},
    {"ci_stability", "pr_ci_wall_time", "duration", "ms", ["ci_runs"]},
    {"ci_stability", "ci_queue_wait", "duration", "ms", ["ci_jobs"]},
    {"ci_stability", "feature_merge_share", "bucketed", "share", ["work_kind"]},
    {"ci_stability", "innocent_dequeues", "count", "merged PRs", ["pulls"]},
    {"ci_stability", "flaky_failure_rate", "rate", "share", ["flake_evidence", "ci_jobs", "ci_runs"]},
    {"ci_stability", "flake_issues_filed", "bucketed", "issues/day", ["flake_issues"]}
  ]

  @impl true
  def id, do: "delivery-speed"
  @impl true
  def version, do: "1"

  @impl true
  def metrics do
    Enum.map(@definitions, &metric/1)
  end

  defp metric({group, name, kind, unit, requires}) do
    better = if name in ["merged_per_hour", "agents_vs_cap", "feature_merge_share"], do: "higher", else: "lower"

    %Metric{
      id: name,
      pack: id(),
      label: String.replace(name, "_", " "),
      group: group,
      kind: kind,
      unit: unit,
      unit_of_analysis: unit_of_analysis(group, name),
      better: better,
      default_direction: direction(name, better),
      requires: requires
    }
  end

  defp unit_of_analysis(_group, name) when name in ["ci_run_failure_rate", "ci_rerun_rate", "pr_ci_wall_time"], do: "CI run"
  defp unit_of_analysis(_group, "merge_group_failure_rate"), do: "merge-group run"
  defp unit_of_analysis(_group, "ci_queue_wait"), do: "job"
  defp unit_of_analysis(_group, "innocent_dequeues"), do: "merged PR"
  defp unit_of_analysis("throughput", _name), do: "hour"
  defp unit_of_analysis(_group, name) when name in ["main_red_events", "reverts", "feature_merge_share", "flaky_failure_rate", "flake_issues_filed"], do: "day"
  defp unit_of_analysis(_group, _name), do: "ticket"

  defp direction("binding_gate", _better), do: "none"
  defp direction(_name, "higher"), do: "increase"
  defp direction(_name, _better), do: "decrease"

  @impl true
  def observations(ids, window, ctx) do
    context =
      ctx
      |> Map.put(:include_accounting, Enum.any?(ids, &(&1 in ["spend_per_merged_ticket", "tokens_per_merged_ticket"])))
      |> Map.put(:metric_ids, ids)

    results =
      case TelemetrySource.load(window, context) do
        {:error, reason} -> Map.new(ids, &{&1, Common.unavailable(reason)})
        {:ok, data} -> Map.new(Enum.filter(metrics(), &(&1.id in ids)), &{&1.id, evaluate(&1, data, window)})
      end

    Map.new(results, fn {id, result} -> {id, {result.coverage, result.observations}} end)
  end

  defp evaluate(%{requires: ["accounting"]} = metric, data, window) do
    case data.accounting do
      {:error, reason} -> Common.unavailable(reason)
      {:ok, usage} -> Tickets.cost(metric.id, data, usage, window)
    end
  end

  defp evaluate(%{requires: ["ci_runs"]}, %{ci_runs_status: :unavailable}, _window), do: Common.unavailable(:github_unavailable)
  defp evaluate(%{id: "flaky_failure_rate"}, %{ci_runs_status: :unavailable}, _window), do: Common.unavailable(:github_unavailable)

  defp evaluate(%{id: "flaky_failure_rate"}, %{flake_evidence: nil}, _window), do: Common.unavailable(:landing_watch_journal_unavailable)
  defp evaluate(%{id: "flaky_failure_rate"}, %{ci_jobs: nil}, _window), do: Common.unavailable(:github_unavailable)
  defp evaluate(%{requires: ["ci_jobs"]}, %{ci_jobs: nil}, _window), do: Common.unavailable(:github_unavailable)

  defp evaluate(metric, data, window) do
    coverage = metric_coverage(metric, data, window)

    if coverage.state == :not_captured do
      Common.result(coverage, [])
    else
      {observations, filtered} = if metric.unit_of_analysis == "ticket", do: Tickets.observations(metric.id, data, window), else: Periods.observations(metric.id, data, window)
      missing_open = Tickets.missing_open?(data, window)
      coverage = if "pr_opened_source_time" in metric.requires and missing_open, do: Map.merge(coverage, %{state: :partial, reason: :pr_open_capture_missing}), else: coverage
      covered_ms = Enum.sum(Enum.map(data.capacity, &DateTime.diff(&1.end, &1.start, :millisecond)))

      coverage =
        if metric.unit_of_analysis == "hour" and covered_ms < DateTime.diff(window.end, window.start, :millisecond),
          do: Map.merge(coverage, %{state: :partial, reason: :fleet_sample_gaps}),
          else: coverage

      Common.result(Map.put(coverage, :filtered, filtered), observations)
    end
  end

  defp metric_coverage(metric, data, window) do
    coverage = Coverage.classify(metric.requires, data.facts, window, data.earliest_at)
    coverage = mark_partial(coverage, data.partial?, :telemetry_incomplete)
    mark_partial(coverage, Enum.any?(metric.requires, &partial_source?(&1, data.source_partials)), :github_source_incomplete)
  end

  defp mark_partial(%{state: :captured} = coverage, true, reason), do: Map.merge(coverage, %{state: :partial, reason: reason})
  defp mark_partial(coverage, _partial?, _reason), do: coverage

  defp partial_source?("ci_runs", partials), do: "ci_runs" in partials
  defp partial_source?("ci_jobs", partials), do: "jobs" in partials
  defp partial_source?("flake_evidence", partials), do: "flake_evidence" in partials
  defp partial_source?("work_kind", partials), do: "pulls" in partials
  defp partial_source?("pulls", partials), do: "pulls" in partials
  defp partial_source?("flake_issues", partials), do: "flake_issues" in partials
  defp partial_source?(_requirement, _partials), do: false
end

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
    {"cost_quality", "reverts", "bucketed", "reverts/day", ["reverts"]}
  ]

  @impl true
  def id, do: "delivery-speed"
  @impl true
  def version, do: "1"

  @impl true
  def metrics do
    Enum.map(@definitions, fn {group, name, kind, unit, requires} ->
      period = group == "throughput" or name in ["main_red_events", "reverts"]
      better = if name in ["merged_per_hour", "agents_vs_cap"], do: "higher", else: "lower"

      %Metric{
        id: name,
        pack: id(),
        label: String.replace(name, "_", " "),
        group: group,
        kind: kind,
        unit: unit,
        unit_of_analysis: if(period, do: if(group == "throughput", do: "hour", else: "day"), else: "ticket"),
        better: better,
        default_direction: if(name == "binding_gate", do: "none", else: if(better == "higher", do: "increase", else: "decrease")),
        requires: requires
      }
    end)
  end

  @impl true
  def observations(ids, window, ctx) do
    rows =
      case TelemetrySource.load(window, Map.put(ctx, :include_accounting, Enum.any?(ids, &(&1 in ["spend_per_merged_ticket", "tokens_per_merged_ticket"])))) do
        {:error, reason} -> Map.new(ids, &{&1, Common.unavailable(reason)})
        {:ok, data} -> Map.new(Enum.filter(metrics(), &(&1.id in ids)), &{&1.id, evaluate(&1, data, window)})
      end

    Map.new(rows, fn {id, result} -> {id, {result.coverage, result.observations}} end)
  end

  defp evaluate(%{requires: ["accounting"]} = metric, data, window) do
    case data.accounting do
      {:error, reason} -> Common.unavailable(reason)
      {:ok, usage} -> Tickets.cost(metric.id, data, usage, window)
    end
  end

  defp evaluate(metric, data, window) do
    coverage = Coverage.classify(metric.requires, data.facts, window, data.earliest_at)
    coverage = if data.partial? and coverage.state == :captured, do: Map.merge(coverage, %{state: :partial, reason: :telemetry_incomplete}), else: coverage

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
end

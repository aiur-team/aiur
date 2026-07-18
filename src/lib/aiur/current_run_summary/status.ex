defmodule Aiur.CurrentRunSummary.Status do
  @moduledoc false

  alias Aiur.CurrentRunProjection.Value

  @spec source_health(map()) :: map()
  def source_health(units) do
    health = Value.get(units, :health)

    %{
      membership: health |> Value.get(:membership, :unknown) |> Value.health(),
      status: health |> Value.get(:status, :unknown) |> Value.health(),
      activity: health |> Value.get(:activity, :unknown) |> Value.health(),
      issue: health |> Value.get(:issue, :unknown) |> Value.health()
    }
  end

  @spec membership_freshness(map()) :: atom()
  def membership_freshness(units) do
    units |> Value.get(:freshness) |> Value.get(:membership) |> Value.freshness()
  end

  @spec health(map(), map()) :: map()
  def health(run, context) do
    reasons =
      []
      |> maybe_reason(not run.valid?, :invalid_run_window)
      |> maybe_reason(context.source_health.membership != :healthy, :unhealthy_membership)
      |> maybe_reason(context.membership_freshness != :fresh, :membership_not_fresh)
      |> maybe_reason(context.source_health.status != :healthy, :unhealthy_status)
      |> maybe_reason(context.source_health.activity != :healthy, :unhealthy_activity)
      |> maybe_reason(context.source_health.issue != :healthy, :unhealthy_issue_facts)
      |> maybe_reason(context.weight_health != :healthy, :unhealthy_weight_facts)
      |> maybe_reason(context.truncated?, :truncated_membership)

    status =
      cond do
        not run.valid? or context.source_health.membership == :unavailable -> :unavailable
        reasons == [] -> :healthy
        true -> :partial
      end

    %{status: status, reasons: reasons}
  end

  @spec freshness(map(), [map()], map(), map(), map()) :: map()
  def freshness(run, members, units, progress, context) do
    source_freshness = normalize_freshness(Value.get(units, :freshness))
    source_statuses = Enum.map(source_freshness, fn {_source, status} -> Value.freshness(status) end)

    status =
      freshness_status(
        run,
        members,
        progress,
        context,
        source_statuses
      )

    %{status: status, sources: source_freshness}
  end

  @spec provenance(map(), map()) :: map()
  def provenance(units, context) do
    generations = Value.get(units, :generation)

    %{
      run_generation: nil,
      membership_generation: Value.get(generations, :membership),
      status_generation: Value.get(generations, :status),
      activity_generation: Value.get(generations, :activity),
      issue_generation: Value.get(generations, :issue),
      membership_health: context.source_health.membership,
      status_health: context.source_health.status,
      activity_health: context.source_health.activity,
      issue_health: context.source_health.issue,
      membership_freshness: context.membership_freshness,
      weight_health: context.weight_health
    }
  end

  defp freshness_status(run, members, progress, context, source_statuses) do
    critical_freshness_status(run, members, context, source_statuses) ||
      contextual_freshness_status(progress, context, source_statuses)
  end

  defp critical_freshness_status(run, members, context, source_statuses) do
    cond do
      not run.valid? or context.source_health.membership == :unavailable -> :unavailable
      context.membership_freshness == :stale or stale_member?(members) -> :stale
      :stale in source_statuses or unavailable_retained_source?(context) -> :stale
      context.weight_health != :healthy -> :stale
      true -> nil
    end
  end

  defp contextual_freshness_status(progress, context, source_statuses) do
    cond do
      context.membership_freshness == :unavailable -> :unavailable
      context.membership_freshness == :unknown or :unknown in source_statuses -> :unknown
      context.membership_freshness == :partial or :partial in source_statuses -> :partial
      degraded_source?(context) or progress.unknown_weight > 0 -> :partial
      true -> :fresh
    end
  end

  defp unavailable_retained_source?(context) do
    Enum.any?(
      [context.source_health.status, context.source_health.activity, context.source_health.issue],
      &(&1 == :unavailable)
    )
  end

  defp degraded_source?(context), do: Enum.any?(Map.values(context.source_health), &(&1 != :healthy))

  defp stale_member?(members) do
    Enum.any?(members, fn
      %{progress: {:unknown, :stale}} -> true
      _member -> false
    end)
  end

  defp normalize_freshness(value) when is_map(value), do: value
  defp normalize_freshness(_value), do: %{}
  defp maybe_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_reason(reasons, false, _reason), do: reasons
end

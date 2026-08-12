defmodule Aiur.CurrentRunProjections.UnitsBuilder do
  @moduledoc false

  alias Aiur.CurrentRunProjections.WeightFacts
  alias AiurWeb.OperatorControlCenter.UnitsRow

  @spec build(map(), map(), map(), map(), (map() -> map())) :: map()
  def build(sources, availability, retained_weights, membership, snapshot_fun) do
    members = membership |> Map.get(:members, []) |> List.wrap()

    weights =
      WeightFacts.resolve(
        members,
        sources.status,
        sources.status_facts,
        retained_weights,
        availability
      )

    inputs = %{
      membership: membership,
      status: sources.status,
      activity: sources.activity,
      decisions: %{entries: [], health: :available, freshness: :fresh},
      issue_facts: %{
        entries: weights.entries,
        entry_freshness: weights.freshness,
        generation: Map.get(sources.status, :generation),
        health: issue_health(weights.health),
        freshness: issue_freshness(weights.health)
      }
    }

    %{
      units: safe_snapshot(snapshot_fun, inputs, membership),
      weight_facts: weights.retained,
      weight_health: weights.health,
      race_signature: weights.race_signature
    }
  end

  @spec empty(map() | nil) :: map()
  def empty(membership \\ nil) do
    membership = membership || empty_membership()

    %{
      version: UnitsRow.version(),
      generation: %{membership: Map.get(membership, :generation)},
      health: %{membership: :unavailable, status: :unavailable, activity: :unavailable, issue: :unavailable},
      freshness: %{membership: :stale, status: :stale, activity: :stale, issue: :stale},
      truncated?: Map.get(membership, :truncated?, false),
      rows: []
    }
  end

  defp safe_snapshot(fun, inputs, membership) do
    case fun.(inputs) do
      snapshot when is_map(snapshot) -> snapshot
      _snapshot -> empty(membership)
    end
  rescue
    _error -> empty(membership)
  catch
    _kind, _reason -> empty(membership)
  end

  defp issue_health(:healthy), do: :available
  defp issue_health(_health), do: :degraded
  defp issue_freshness(:healthy), do: :fresh
  defp issue_freshness(_health), do: :stale

  defp empty_membership do
    %{
      run_id: nil,
      generation: 0,
      health: {:unavailable, :not_read},
      freshness: %{status: :stale},
      truncated?: false,
      members: []
    }
  end
end

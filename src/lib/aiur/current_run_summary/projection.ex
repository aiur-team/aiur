defmodule Aiur.CurrentRunSummary.Projection do
  @moduledoc false

  alias Aiur.CurrentRunProjection.Value
  alias Aiur.CurrentRunSummary.{Facts, Progress, Status}

  @spec snapshot(map()) :: map()
  def snapshot(inputs) when is_map(inputs) do
    units = Value.get(inputs, :units)
    rows = Facts.rows(units)
    run = inputs |> Value.get(:run) |> Facts.run()
    members = Facts.members(rows)
    counts = Facts.counts(rows, members)
    weights = Facts.weights(members)
    denominator_generation = Value.get(inputs, :denominator_generation, 0)

    weight_status = Value.get(inputs, :weight_health, :healthy)

    context = %{
      counts: counts,
      denominator_generation: denominator_generation,
      membership_freshness: Status.membership_freshness(units),
      source_health: Status.source_health(units),
      truncated?: Value.get(units, :truncated?, false) == true,
      weight_health: Value.health(weight_status),
      weight_status: weight_status
    }

    %{progress: progress, eta: eta} = Progress.build(members, weights, run, context)

    %{
      version: Aiur.CurrentRunSummary.version(),
      generation: Value.get(inputs, :generation, 0),
      run: run,
      counts: counts,
      weights: weights,
      progress: progress,
      denominator: %{generation: denominator_generation, signature: Facts.denominator_signature(rows)},
      eta: eta,
      health: Status.health(run, context),
      freshness: Status.freshness(run, members, units, progress, context),
      sources: Status.provenance(units, context)
    }
  end

  def snapshot(_inputs), do: snapshot(%{})

  @spec denominator_signature([map()]) :: String.t()
  defdelegate denominator_signature(rows), to: Facts
end

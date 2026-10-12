defmodule Aiur.BuildQueue.WriteEvidence do
  @moduledoc false

  @spec fresh?(map(), String.t()) :: boolean()
  def fresh?(context, id) do
    prerequisites = for edge <- context.document.edges, edge.dependent == id, do: edge.prerequisite
    now = context.clock.()

    Enum.all?([id | prerequisites], fn subject ->
      case context.observations[subject] do
        nil -> false
        observation -> observation.observed_at_ms <= now and now - observation.observed_at_ms <= context.observation_max_age_ms
      end
    end)
  end
end

defmodule AiurWeb.BuildOrder.PlanningSource.FeatureIconGuard do
  @moduledoc false
  require Logger
  alias Aiur.{BuildOrder.FeatureDefaults, Heroicons}

  @spec sanitize(map()) :: map()
  def sanitize(pack) do
    workstreams = Map.get(pack.metadata, "workstreams", [])
    projection = Map.get(pack.metadata, "label_projection", %{})

    general =
      case Aiur.Config.settings() do
        {:ok, settings} -> settings.build_order.general_epics
        _ -> []
      end

    {workstreams, collisions} =
      Enum.map_reduce(List.wrap(workstreams), [], fn
        %{"id" => id} = workstream, found when is_binary(id) ->
          workstream = Map.merge(FeatureDefaults.get(id), workstream)
          icon = Map.get(workstream, "icon")
          collision = Enum.find(general, &collides_on_member?(&1, id, icon, pack, projection))
          if collision && is_binary(icon), do: {Map.put(workstream, "icon", Heroicons.generic_name()), [{id, collision.key} | found]}, else: {workstream, found}

        workstream, found ->
          {workstream, found}
      end)

    Enum.each(Enum.uniq_by(collisions, &elem(&1, 0)), fn {id, epic} ->
      Logger.warning("planning feature #{id} icon collides with matching general epic #{epic}; using generic icon")
    end)

    %{pack | metadata: Map.put(pack.metadata, "workstreams", workstreams)}
  end

  defp collides_on_member?(epic, id, icon, pack, projection) do
    is_binary(icon) and Heroicons.canonical_name(epic.icon) == Heroicons.canonical_name(icon) and
      Enum.any?(pack.tickets, fn ticket ->
        ticket.lane == id and not MapSet.disjoint?(MapSet.new(epic.labels), projected_labels(ticket, id, projection))
      end)
  end

  defp projected_labels(ticket, workstream_id, projection) do
    workstreams = Map.get(projection, "workstreams", %{})
    phases = Map.get(projection, "phases", %{})
    complexities = Map.get(projection, "complexities", %{})
    required = Map.get(projection, "required_ticket_labels", [])
    lane = if is_map(workstreams), do: Map.get(workstreams, workstream_id), else: nil
    phase = if is_map(phases), do: Map.get(phases, to_string(ticket.phase)), else: nil
    complexity = if is_map(complexities), do: Map.get(complexities, to_string(ticket.complexity)), else: nil
    labels = List.wrap(required) ++ [Map.get(projection, "build_order"), lane, phase, complexity]
    labels |> Enum.filter(&is_binary/1) |> Enum.map(&String.downcase/1) |> MapSet.new()
  end
end

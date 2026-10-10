defmodule Aiur.AlertFeed.Projection do
  @moduledoc false

  alias Aiur.AlertTopic

  @spec resolve([map()]) :: [map()]
  def resolve(alerts) do
    alerts
    |> Enum.with_index()
    |> Enum.reduce({%{}, %{}}, &step/2)
    |> elem(0)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp step({alert, index}, {kept, active}) do
    case AlertTopic.resolved_attention_key(alert) do
      nil -> keep(alert, index, kept, active)
      key -> keep(alert, index, Map.drop(kept, Map.get(active, key, [])), Map.delete(active, key))
    end
  end

  defp keep(%{"needs_attention" => true} = alert, index, kept, active) do
    case AlertTopic.attention_key(alert) do
      nil ->
        {Map.put(kept, index, alert), active}

      key ->
        previous_indexes = Map.get(active, key, [])
        previous = Map.get(kept, List.first(previous_indexes), %{})
        first_seen = previous["first_seen_at"] || previous["timestamp"] || alert["timestamp"]
        alert = Map.put(alert, "first_seen_at", first_seen)
        {kept |> Map.drop(previous_indexes) |> Map.put(index, alert), Map.put(active, key, [index])}
    end
  end

  defp keep(alert, index, kept, active) do
    key = AlertTopic.attention_key(alert)
    active = if key, do: Map.update(active, key, [index], &[index | &1]), else: active
    {Map.put(kept, index, alert), active}
  end
end

defmodule Aiur.Orchestrator.InstanceHeartbeatMetadata.SizeBudget do
  @moduledoc false

  @max_bytes 8_192

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Trims heartbeat data until its JSON fits `max`, cheapest loss first, and records
  the cuts in `"trimmed"` so a reader can tell "omitted for size" from "unknown".
  Counts, capacity, executor presence, identity and ownership keys are never cut.
  """
  @spec fit(map(), pos_integer()) :: map()
  def fit(data, max) do
    steps = [
      {"agent_titles", &truncate_titles/1},
      {"agents", &Map.delete(&1, "agents")},
      {"held_tickets", &truncate(&1, "held_tickets", 50)},
      {"projects", &truncate(&1, "projects", 25)}
    ]

    Enum.reduce_while(steps, {data, []}, fn {name, fun}, {acc, cuts} ->
      if size(acc, cuts) <= max do
        {:halt, {acc, cuts}}
      else
        {:cont, {fun.(acc), cuts ++ [name]}}
      end
    end)
    |> then(fn {acc, cuts} -> if cuts == [], do: acc, else: Map.put(acc, "trimmed", cuts) end)
  end

  defp size(data, cuts), do: byte_size(Jason.encode!(if(cuts == [], do: data, else: Map.put(data, "trimmed", cuts))))

  defp truncate_titles(%{"agents" => agents} = data) when is_list(agents) do
    %{data | "agents" => Enum.map(agents, &Map.update(&1, "title", nil, fn t -> truncate_bytes(t, 80) end))}
  end

  defp truncate_titles(data), do: data

  defp truncate_bytes(t, n) when is_binary(t) and byte_size(t) > n, do: binary_part(t, 0, n) |> String.chunk(:valid) |> Enum.filter(&String.valid?/1) |> Enum.join()
  defp truncate_bytes(t, _), do: t

  defp truncate(data, key, n) do
    case data do
      %{^key => list} when is_list(list) and length(list) > n -> data |> Map.put(key, Enum.take(list, n)) |> Map.put(key <> "_truncated", true)
      _ -> data
    end
  end
end

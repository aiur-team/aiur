defmodule Aiur.TestSupport.BuildHome.UnfiledFixture do
  @moduledoc "The frozen live dataset with the design's final two waves represented as unfiled work."

  def convert(data) do
    ids = Map.new(Enum.filter(data["sections"]["plan"], &(&1["wave"] >= 5)), &{&1["id"], "pack:build-plan/BP-#{&1["num"]}"})

    sections = Map.new(data["sections"], fn {section, rows} -> {section, Enum.map(rows, &convert_row(&1, ids))} end)
    data |> Map.put("sections", sections) |> put_in(["sources", "packs"], source(data, "ok", nil))
  end

  def unavailable(data) do
    data
    |> put_in(["sections", "plan"], Enum.reject(data["sections"]["plan"], &is_map(&1["src"])))
    |> put_in(["sources", "packs"], source(data, "unavailable", "1 of 2 planning packs could not be read: broken.json"))
  end

  defp convert_row(row, ids) do
    row =
      row
      |> Map.update!("deps", &Enum.map(&1, fn id -> Map.get(ids, id, id) end))
      |> Map.update!("children", &Enum.map(&1, fn id -> Map.get(ids, id, id) end))
      |> Map.update!("dep_states", &Map.new(&1, fn {id, state} -> {Map.get(ids, id, id), state} end))

    case ids[row["id"]] do
      nil -> row
      # Preserve frozen design estimates for identity parity; the live producer leaves estimates unknown.
      id -> Map.merge(row, %{"id" => id, "num" => nil, "qpos" => nil, "src" => %{"kind" => "pack", "path" => "docs/build-plan.md", "wave" => row["wave"]}})
    end
  end

  defp source(data, state, reason), do: %{"state" => state, "observed_at" => data["now"], "reason" => reason}
end

defmodule Aiur.RunTelemetry.RepoTimeline.Rows do
  @moduledoc false
  alias Aiur.TicketBranch

  @spec cursor([map()]) :: String.t() | nil
  def cursor(rows) do
    rows |> Enum.filter(&(&1["type"] == "commit")) |> Enum.map(& &1["ts"]) |> Enum.max(fn -> nil end)
  end

  @spec appended([map()], [map()], [map()], String.t()) :: {:ok, [map()]} | {:error, term()}
  def appended(previous, commits, tags, observed_at) do
    seen = MapSet.new(previous, &key/1)
    red = Enum.reduce(previous, false, &red_state/2)
    commits = commits |> Enum.uniq_by(& &1["oid"]) |> Enum.sort_by(&{&1["committedDate"], &1["oid"]})
    latest = previous |> Enum.filter(&(&1["type"] == "commit")) |> Enum.max_by(&{&1["ts"], &1["sha"]}, fn -> %{} end)
    candidates = Enum.filter(commits, &(not MapSet.member?(seen, {"commit", &1["oid"], nil}) or &1["oid"] == latest["sha"]))

    with {:ok, tag_rows} <- tags(tags) do
      floor = previous |> Enum.filter(&(&1["type"] in ["main_red_start", "main_red_end"])) |> List.last()
      {commit_rows, _red, _floor} = Enum.reduce(candidates, {[], red, floor && floor["ts"]}, &commit_rows(&1, &2, seen, observed_at))
      rows = Enum.reject(Enum.reverse(commit_rows) ++ tag_rows, &MapSet.member?(seen, key(&1)))
      {:ok, Enum.uniq_by(rows, &key/1)}
    end
  end

  defp key(row), do: {row["type"], row["sha"], row["tag"]}
  defp red_state(%{"type" => "main_red_start"}, _red), do: true
  defp red_state(%{"type" => "main_red_end"}, _red), do: false
  defp red_state(_row, red), do: red

  defp commit_rows(commit, {rows, red, floor}, seen, observed_at) do
    pull = commit |> get_in(["associatedPullRequests", "nodes"]) |> List.wrap() |> List.first() || %{}
    rollup = get_in(commit, ["statusCheckRollup", "state"])

    row = %{
      "schema_version" => 1,
      "type" => "commit",
      "sha" => commit["oid"],
      "ts" => commit["committedDate"],
      "pr_number" => pull["number"],
      "ticket" => TicketBranch.ticket_id(pull["headRefName"]),
      "rollup_state" => rollup,
      "revert_of" => revert_of(commit["message"] || "") || commit["revertOid"]
    }

    {boundary, next_red} = transition(rollup, red)
    known_boundary = MapSet.member?(seen, {boundary, row["sha"], nil})

    boundary_rows =
      if boundary && not known_boundary do
        event = Map.take(row, ["schema_version", "sha", "ts"]) |> Map.put("type", boundary)
        event = if MapSet.member?(seen, key(row)), do: Map.merge(event, %{"ts" => observed_at, "source" => "observation"}), else: event
        [causal_boundary(event, floor)]
      else
        []
      end

    {boundary_rows ++ [row] ++ rows, if(known_boundary, do: red, else: next_red), if(boundary_rows == [], do: floor, else: hd(boundary_rows)["ts"])}
  end

  defp causal_boundary(event, nil), do: event

  defp causal_boundary(event, floor) do
    {:ok, timestamp, _} = DateTime.from_iso8601(event["ts"])
    {:ok, earliest, _} = DateTime.from_iso8601(floor)
    if DateTime.compare(timestamp, earliest) == :lt, do: Map.merge(event, %{"ts" => floor, "source" => "observation"}), else: event
  end

  defp transition("FAILURE", false), do: {"main_red_start", true}
  defp transition("ERROR", false), do: {"main_red_start", true}
  defp transition("SUCCESS", true), do: {"main_red_end", false}
  defp transition(_state, red), do: {nil, red}

  defp revert_of(message) do
    case Regex.run(~r/This reverts commit ([a-fA-F0-9]+)\b/, message) do
      [_, sha] -> sha
      _ -> nil
    end
  end

  defp tags(tags) do
    Enum.reduce_while(tags, {:ok, []}, fn tag, {:ok, rows} ->
      case tag_target(tag["target"]) do
        %{"__typename" => "Commit", "oid" => sha, "committedDate" => ts} ->
          row = %{"schema_version" => 1, "type" => "tag", "sha" => sha, "ts" => ts, "tag" => tag["name"]}
          {:cont, {:ok, [row | rows]}}

        _ ->
          {:halt, {:error, :unsupported_tag_target}}
      end
    end)
  end

  defp tag_target(%{"__typename" => "Tag", "target" => target}), do: tag_target(target)
  defp tag_target(target), do: target
end

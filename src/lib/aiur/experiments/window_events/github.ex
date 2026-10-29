defmodule Aiur.Experiments.WindowEvents.GitHub do
  @moduledoc false
  alias Aiur.Experiments.Sources.Common
  alias Aiur.Experiments.WindowEvents
  alias Aiur.RunTelemetry

  @spec collect(String.t(), map(), map(), keyword()) :: {[map()], [String.t()]}
  def collect(repo, sources, range, opts) do
    {data, missing} = Keyword.get(opts, :github_fun, &Aiur.RunTelemetry.window_event_sources/4).(repo, sources, range, opts)
    {data, invalid?} = validate_rows(data)
    missing = if Enum.any?(Map.get(data, "tags", []), &is_nil(tag_time(&1))), do: ["github" | missing], else: missing
    missing = if invalid?, do: ["github" | missing], else: missing
    pulls = Map.get(data, "pulls", [])
    missing = if Enum.any?(pulls, &(get_in(&1, ["closingIssuesReferences", "pageInfo", "hasNextPage"]) == true)), do: ["github" | missing], else: missing
    missing = if Enum.any?(pulls, &(get_in(&1, ["timelineItems", "pageInfo", "hasNextPage"]) == true)), do: ["github" | missing], else: missing

    missing = if sources["required_workflows"] == [], do: ["main_red" | missing], else: missing

    events =
      Enum.map(pulls, &pull(&1, repo)) ++
        releases(Map.get(data, "releases", [])) ++
        tags(Map.get(data, "tags", [])) ++ incidents(Map.get(data, "incidents", []), repo) ++ ci_runs(Map.get(data, "ci_runs", []), sources) ++ main_red(Map.get(data, "runs", []), sources)

    {events, Enum.uniq(missing)}
  end

  defp validate_rows(data) do
    Enum.reduce(
      [{"pulls", "mergedAt", "number"}, {"releases", "publishedAt", "databaseId"}, {"incidents", "createdAt", "number"}, {"ci_runs", "updated_at", "id"}, {"runs", "updated_at", "id"}],
      {data, false},
      fn {source, at, id}, {data, invalid?} ->
        rows = Map.get(data, source, [])
        good = Enum.filter(rows, &(is_map(&1) and not is_nil(&1[id]) and not is_nil(Common.timestamp(&1[at]))))
        {Map.put(data, source, good), invalid? or length(good) != length(rows)}
      end
    )
  end

  defp pull(row, repo) do
    epics = nodes(row, "closingIssuesReferences") |> Enum.map(&get_in(&1, ["parent", "number"])) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

    attrs = %{
      "epic" => List.first(epics),
      "epics" => epics,
      "labels" => Enum.map(nodes(row, "labels"), & &1["name"]) |> Enum.sort(),
      "paths" => Enum.map(nodes(row, "files"), & &1["path"]) |> Enum.sort(),
      "author" => get_in(row, ["author", "login"])
    }

    labels = attrs["labels"]
    attrs = Map.put(attrs, "work_kind", work_kind(labels, row["title"]))

    WindowEvents.event("merged_pr", "github", row["number"], row["mergedAt"], ref: repo <> "#" <> to_string(row["number"]), title: row["title"], attrs: attrs)
  end

  @doc false
  @spec work_kind([String.t()], String.t() | nil) :: String.t()
  def work_kind(labels, title), do: RunTelemetry.work_kind(labels, title)

  defp nodes(row, key), do: get_in(row, [key, "nodes"]) || []

  defp releases(rows) do
    for row <- rows, row["isDraft"] == false and is_binary(row["publishedAt"]) do
      WindowEvents.event("release", "github", row["databaseId"], row["publishedAt"], ref: row["url"], title: row["name"], attrs: %{"tag" => row["tagName"]})
    end
  end

  defp tags(rows) do
    Enum.flat_map(rows, fn row ->
      at = tag_time(row)
      if Common.timestamp(at), do: [WindowEvents.event("release", "github", "tag:" <> row["name"], at, ref: row["name"], attrs: %{"tag" => row["name"], "type" => "tag"})], else: []
    end)
  end

  defp tag_time(row) when is_map(row) do
    target = row["target"] || %{}
    get_in(target, ["tagger", "date"]) || target["committedDate"] || get_in(target, ["target", "committedDate"])
  end

  defp tag_time(_row), do: nil

  defp incidents(rows, repo) do
    Enum.map(rows, fn row ->
      WindowEvents.event("incident", "github", row["number"], row["createdAt"],
        ref: repo <> "#" <> to_string(row["number"]),
        title: row["title"],
        from: row["createdAt"],
        to: row["closedAt"],
        attrs: %{"labels" => Enum.map(nodes(row, "labels"), & &1["name"]) |> Enum.sort()}
      )
    end)
  end

  @spec ci_runs([map()], map()) :: [map()]
  def ci_runs(runs, sources) do
    runs
    |> Enum.filter(&(&1["name"] in sources["required_workflows"] and &1["event"] in ["pull_request", "merge_group"] and &1["status"] == "completed" and &1["conclusion"] in ["failure", "success"]))
    |> Enum.map(fn run ->
      WindowEvents.event("ci_run", "github", run["id"], run["updated_at"],
        ref: run["html_url"],
        attrs: %{"workflow" => run["name"], "event" => run["event"], "conclusion" => run["conclusion"], "run_attempt" => run["run_attempt"], "run_started_at" => run["run_started_at"]}
      )
    end)
  end

  @spec main_red([map()], map()) :: [map()]
  def main_red(runs, sources) do
    runs
    |> Enum.filter(&(&1["head_branch"] == sources["base_branch"] and &1["name"] in sources["required_workflows"] and &1["event"] != "pull_request" and &1["status"] == "completed"))
    |> Enum.group_by(& &1["name"])
    |> Enum.flat_map(fn {workflow, rows} ->
      {events, open} = rows |> Enum.sort_by(&{&1["updated_at"], &1["id"]}) |> Enum.reduce({[], nil}, &red_run(&1, &2, workflow))
      if open, do: [red_event(open, nil, workflow) | events], else: events
    end)
  end

  defp red_run(row, {events, open}, workflow) do
    cond do
      row["conclusion"] in ~w(failure timed_out startup_failure action_required) -> {events, open || row}
      row["conclusion"] == "success" and open -> {[red_event(open, row["updated_at"], workflow) | events], nil}
      true -> {events, open}
    end
  end

  defp red_event(first, stop, workflow),
    do: WindowEvents.event("main_red", "github", first["id"], first["updated_at"], from: first["updated_at"], to: stop, ref: first["html_url"], attrs: %{"workflow" => workflow})
end

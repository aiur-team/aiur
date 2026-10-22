defmodule Aiur.RunTelemetry.WindowEventSources do
  @moduledoc false
  alias Aiur.GitHub.Transport
  alias Aiur.RunTelemetry.WindowEventSources.CiRuns

  @pulls """
  query ExperimentWindowPulls($query: String!, $cursor: String) {
    search(query: $query, type: ISSUE, first: 50, after: $cursor) {
      issueCount pageInfo { hasNextPage endCursor }
      nodes { ... on PullRequest { number title mergedAt headRefOid url author { login }
        labels(first: 20) { nodes { name } }
        files(first: 50) { nodes { path } }
        timelineItems(first: 100, itemTypes: [REMOVED_FROM_MERGE_QUEUE_EVENT]) {
          pageInfo { hasNextPage }
          nodes { __typename ... on RemovedFromMergeQueueEvent { createdAt reason beforeCommit { oid } } }
        }
        closingIssuesReferences(first: 5) { nodes { number title labels(first: 20) { nodes { name } } parent { number } } pageInfo { hasNextPage } }
      } }
    }
  }
  """
  @releases """
  query ExperimentWindowReleases($owner: String!, $name: String!, $cursor: String) {
    repository(owner: $owner, name: $name) {
      releases(first: 100, after: $cursor) { nodes { databaseId name tagName publishedAt url isDraft }
        pageInfo { hasNextPage endCursor } }
    }
  }
  """
  @tags """
  query ExperimentWindowTags($owner: String!, $name: String!, $cursor: String) {
    repository(owner: $owner, name: $name) {
      refs(refPrefix: "refs/tags/", first: 100, after: $cursor) {
        nodes { name target { __typename ... on Commit { committedDate oid }
          ... on Tag { tagger { date } target { __typename ... on Commit { committedDate oid } } } } }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
  """
  @incidents """
  query ExperimentWindowIncidents($query: String!, $cursor: String) {
    search(query: $query, type: ISSUE, first: 100, after: $cursor) {
      issueCount nodes { ... on Issue { number title createdAt closedAt url labels(first: 50) { nodes { name } } } }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  @spec fetch(String.t(), map(), map(), keyword()) :: {map(), [String.t()]}
  def fetch(repo, sources, range, opts) do
    with [owner, name] <- String.split(repo, "/"), {:ok, token} <- Transport.require_token(opts) do
      request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      variables = %{"owner" => owner, "name" => name}
      dates = range.start <> ".." <> range.end
      incidents = "repo:#{repo} is:issue created:<=#{range.end} label:" <> Enum.map_join(sources["incident_labels"] || [], ",", &Jason.encode!/1)
      flake_issues = "repo:#{repo} is:issue created:#{dates} label:" <> Enum.map_join(sources["flake_issue_labels"] || [], ",", &Jason.encode!/1)
      include = Map.get(sources, "include_sources", default_sources(sources))

      reads = [
        {"pulls", fn -> pulls(request, token, repo, sources["base_branch"], range) end},
        {"releases", fn -> pages(request, token, @releases, variables, ["repository", "releases"]) end},
        {"tags", fn -> pages(request, token, @tags, variables, ["repository", "refs"]) end},
        {"incidents", fn -> if sources["incident_labels"] == [], do: {:ok, []}, else: pages(request, token, @incidents, %{"query" => incidents}, ["search"]) end},
        {"flake_issues", fn -> if sources["flake_issue_labels"] in [nil, []], do: {:ok, []}, else: pages(request, token, @incidents, %{"query" => flake_issues}, ["search"]) end},
        {"runs", fn -> runs(request, token, repo, sources["base_branch"], range) end},
        {"ci_runs", fn -> CiRuns.fetch(request, token, repo, sources["required_workflows"] || [], range) end}
      ]

      {data, missing} = reads |> Enum.filter(&(elem(&1, 0) in include)) |> Enum.reduce({%{}, []}, &collect_source/2)
      {data, missing} = if "jobs" in include and is_list(data["ci_runs"]), do: collect_source({"jobs", fn -> jobs(request, token, repo, data["ci_runs"]) end}, {data, missing}), else: {data, missing}
      {data, Enum.uniq(missing)}
    else
      _error -> {%{}, ["github"]}
    end
  end

  defp default_sources(sources) do
    base = ~w(pulls releases tags incidents runs)
    base = if (sources["required_workflows"] || []) == [], do: base, else: ["ci_runs" | base]
    if (sources["flake_issue_labels"] || []) == [], do: base, else: ["flake_issues" | base]
  end

  @doc false
  @spec workflow_runs(String.t(), String.t(), map(), keyword()) :: {:ok, [map()]} | {:partial, [map()]} | {:error, term()}
  def workflow_runs(repo, branch, range, opts \\ []) do
    with {:ok, token} <- Transport.require_token(opts) do
      runs(Keyword.get(opts, :request_fun, &Transport.default_request_fun/1), token, repo, branch, range)
    end
  end

  defp collect_source({source, read}, {data, missing}) do
    case read_source(read) do
      {:ok, rows} ->
        partial? = source == "pulls" and Enum.any?(rows, &incomplete_pull_timeline?/1)
        data = Map.put(data, source, rows)
        data = if partial?, do: Map.put(data, source <> "_partial", true), else: data
        {data, if(partial?, do: ["github" | missing], else: missing)}

      {:partial, rows} ->
        {data |> Map.put(source, rows) |> Map.put(source <> "_partial", true), ["github" | missing]}

      {:error, _reason} ->
        {data, ["github" | missing]}
    end
  end

  defp incomplete_pull_timeline?(pull) do
    get_in(pull, ["timelineItems", "pageInfo", "hasNextPage"]) == true or
      get_in(pull, ["closingIssuesReferences", "pageInfo", "hasNextPage"]) == true
  end

  defp pulls(request, token, repo, branch, range) do
    query_days = for day <- days(range), do: "repo:#{repo} is:pr is:merged base:#{branch} merged:#{Date.to_iso8601(day)}"

    {rows, partial?} =
      Enum.reduce(query_days, {[], false}, fn query, {rows, partial?} ->
        case pages(request, token, @pulls, %{"query" => query}, ["search"]) do
          {:ok, page_rows} -> {rows ++ page_rows, partial?}
          {:partial, page_rows} -> {rows ++ page_rows, true}
          {:error, _reason} -> {rows, true}
        end
      end)

    if partial?, do: {:partial, rows}, else: {:ok, rows}
  end

  defp days(range) do
    with {:ok, start_at, _} <- DateTime.from_iso8601(range.start),
         {:ok, end_at, _} <- DateTime.from_iso8601(range.end) do
      last_day = end_at |> DateTime.add(-1, :second) |> DateTime.to_date()
      first_day = DateTime.to_date(start_at)
      if Date.compare(last_day, first_day) == :lt, do: [], else: Enum.to_list(Date.range(first_day, last_day))
    else
      _ -> []
    end
  end

  defp read_source(read) do
    read.()
  rescue
    _error -> {:error, :source_failed}
  catch
    :exit, _reason -> {:error, :source_failed}
  end

  defp pages(request, token, query, variables, path, rows \\ [], seen \\ []) do
    with {:ok, body, _response} <- Transport.github_graphql_response(request, token, query, variables, caller: "experiment_window_events"),
         %{"nodes" => nodes, "pageInfo" => info} when is_list(nodes) <- get_in(body, ["data" | path]) do
      rows = rows ++ nodes
      count = get_in(body, ["data" | path])["issueCount"] || 0
      next_page(request, token, query, variables, path, rows, seen, Map.put(info, "issueCount", count))
    else
      _error -> if rows == [], do: {:error, :github_unavailable}, else: {:partial, rows}
    end
  end

  defp next_page(request, token, query, variables, path, rows, seen, info) do
    cursor = info["endCursor"]

    cond do
      info["hasNextPage"] == false -> if info["issueCount"] > 1000, do: {:partial, rows}, else: {:ok, rows}
      length(seen) >= 9 or is_nil(cursor) or cursor in seen -> {:partial, rows}
      true -> pages(request, token, query, Map.put(variables, "cursor", cursor), path, rows, [cursor | seen])
    end
  end

  defp runs(request, token, repo, branch, range, page \\ 1, rows \\ []) do
    params = %{created: range.start <> ".." <> range.end, per_page: 100, page: page} |> maybe_branch(branch) |> URI.encode_query()
    req = %{method: :get, url: Transport.base_url() <> "/repos/#{repo}/actions/runs?" <> params, token: token, caller: "experiment_window_events"}

    case request.(req) do
      {:ok, %{status: 200, body: %{"workflow_runs" => runs, "total_count" => total}}} when is_list(runs) ->
        rows = rows ++ runs

        cond do
          length(rows) >= total -> {:ok, rows}
          page >= 10 or runs == [] -> {:partial, rows}
          true -> runs(request, token, repo, branch, range, page + 1, rows)
        end

      _error ->
        if rows == [], do: {:error, :github_unavailable}, else: {:partial, rows}
    end
  end

  defp maybe_branch(params, branch) when is_binary(branch) and branch != "", do: Map.put(params, :branch, branch)
  defp maybe_branch(params, _branch), do: params

  defp jobs(request, token, repo, runs) do
    samples = sample_job_runs(runs)

    {rows, partial?} =
      Enum.reduce(samples, {[], length(samples) != length(runs)}, fn run, {rows, incomplete?} ->
        case run_jobs(request, token, repo, run["id"], 1, [], 0) do
          {:ok, jobs} -> {rows ++ Enum.map(jobs, &Map.put_new(&1, "run_id", run["id"])), incomplete?}
          {:partial, jobs} -> {rows ++ Enum.map(jobs, &Map.put_new(&1, "run_id", run["id"])), true}
          {:error, _reason} -> {rows, true}
        end
      end)

    if partial?, do: {:partial, rows}, else: {:ok, rows}
  rescue
    _error -> {:error, :github_unavailable}
  end

  defp sample_job_runs(runs) do
    samples =
      runs
      |> Enum.group_by(fn run -> {run["name"], run["event"], run_day(run["created_at"])} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {_key, group} -> Enum.take(Enum.sort_by(group, & &1["created_at"], :desc), 3) end)

    Enum.take(samples, 200)
  end

  defp run_day(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> DateTime.to_date(at)
      _ -> nil
    end
  end

  defp run_day(_value), do: nil

  defp run_jobs(_request, _token, _repo, _run_id, _page, rows, total) when length(rows) >= total and total > 0, do: {:ok, rows}

  defp run_jobs(request, token, repo, run_id, page, rows, total) when page <= 10 do
    query = URI.encode_query(%{per_page: 100, page: page})
    req = %{method: :get, url: Transport.base_url() <> "/repos/#{repo}/actions/runs/#{run_id}/jobs?" <> query, token: token, caller: "experiment_window_events"}

    case request.(req) do
      {:ok, %{status: 200, body: %{"jobs" => jobs} = body}} when is_list(jobs) ->
        all = rows ++ jobs
        count = max(total, Map.get(body, "total_count", length(all)))

        cond do
          length(all) >= count -> {:ok, all}
          jobs == [] -> {:partial, all}
          page == 10 -> {:partial, all}
          true -> run_jobs(request, token, repo, run_id, page + 1, all, count)
        end

      _error when rows == [] ->
        {:error, :jobs_unavailable}

      _error ->
        {:partial, rows}
    end
  end

  defp run_jobs(_request, _token, _repo, _run_id, _page, rows, _total), do: {:partial, rows}
end

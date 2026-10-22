defmodule Aiur.RunTelemetry.WindowEventSourcesTest do
  use ExUnit.Case, async: true

  alias Aiur.RunTelemetry

  @range %{start: "2026-10-08T00:00:00Z", end: "2026-10-11T00:00:00Z"}

  test "main runs remain branch-filtered while CI runs are queried by workflow, event, and day" do
    parent = self()

    request = fn req ->
      send(parent, {:request, req})

      cond do
        req.method == :get and req.url =~ "/actions/workflows?" ->
          {:ok, %{status: 200, body: %{"workflows" => [%{"id" => 42, "name" => "CI", "path" => ".github/workflows/ci.yml"}], "total_count" => 1}}}

        req.method == :get and req.url =~ "/actions/workflows/42/runs?" ->
          {:ok, %{status: 200, body: %{"workflow_runs" => [], "total_count" => 0}}}

        req.method == :get and req.url =~ "/actions/runs?" ->
          {:ok, %{status: 200, body: %{"workflow_runs" => [%{"id" => 9, "head_branch" => "main"}], "total_count" => 1}}}

        req.method == :post and req.body["query"] =~ "ExperimentWindowPulls" ->
          {:ok, %{status: 200, body: %{"data" => %{"search" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}, "issueCount" => 0}}}}}

        true ->
          key = if req.body["query"] =~ "ExperimentWindowReleases", do: "releases", else: "refs"
          {:ok, %{status: 200, body: %{"data" => %{"repository" => %{key => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}}}}}}
      end
    end

    sources = %{
      "base_branch" => "main",
      "required_workflows" => ["CI"],
      "incident_labels" => [],
      "include_sources" => ["runs", "ci_runs"]
    }

    {data, []} = RunTelemetry.window_event_sources("owner/repo", sources, @range, token: "test-gh-token", request_fun: request)
    assert [%{"id" => 9}] = data["runs"]
    assert data["ci_runs"] == []

    requests =
      for _ <- 1..8 do
        assert_receive {:request, req}, 1_000
        req
      end

    [main_req] = Enum.filter(requests, &(&1.method == :get and &1.url =~ "/actions/runs?"))
    main_params = main_req.url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert main_params["branch"] == "main"
    assert main_params["created"] == @range.start <> ".." <> @range.end

    ci_params =
      requests
      |> Enum.filter(&(&1.method == :get and &1.url =~ "/actions/workflows/42/runs?"))
      |> Enum.map(fn req -> req.url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() end)

    assert length(ci_params) == 6
    assert Enum.all?(ci_params, &(&1["event"] in ["pull_request", "merge_group"]))
    assert Enum.all?(ci_params, &(&1["created"] in ["2026-10-08", "2026-10-09", "2026-10-10"]))
  end

  test "main run page cap retains rows and signals partial coverage" do
    request = fn req ->
      if req.method == :get do
        {:ok, %{status: 200, body: %{"workflow_runs" => [%{"id" => 1}], "total_count" => 2_000}}}
      else
        {:error, :offline}
      end
    end

    sources = %{"base_branch" => "main", "required_workflows" => [], "incident_labels" => [], "include_sources" => ["runs"]}
    {data, ["github"]} = RunTelemetry.window_event_sources("owner/repo", sources, @range, token: "test-gh-token", request_fun: request)
    assert length(data["runs"]) == 10
    assert data["runs_partial"]
  end

  test "merged pull searches are sliced by day" do
    parent = self()

    request = fn req ->
      send(parent, {:request, req})
      {:ok, %{status: 200, body: %{"data" => %{"search" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}, "issueCount" => 0}}}}}
    end

    sources = %{"base_branch" => "main", "include_sources" => ["pulls"]}
    assert {%{"pulls" => []}, []} = RunTelemetry.window_event_sources("owner/repo", sources, @range, token: "test-gh-token", request_fun: request)

    queries =
      for _ <- 1..3 do
        assert_receive {:request, req}, 1_000
        assert req.caller == "experiment_window_events"
        assert req.body["query"] =~ "closingIssuesReferences(first: 5)"
        req.body["variables"]["query"]
      end

    expected = Enum.map(~w(2026-10-08 2026-10-09 2026-10-10), &("repo:owner/repo is:pr is:merged base:main merged:" <> &1))
    assert Enum.sort(queries) == Enum.sort(expected)
  end

  test "job detail samples a bounded number per workflow, event, and day" do
    parent = self()

    request = fn req ->
      send(parent, {:request, req})

      cond do
        req.url =~ "/actions/workflows?" ->
          {:ok, %{status: 200, body: %{"workflows" => [%{"id" => 42, "name" => "CI"}], "total_count" => 1}}}

        req.url =~ "/actions/workflows/42/runs?" ->
          params = req.url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

          if params["event"] == "pull_request" and params["created"] == "2026-10-08" do
            runs = for id <- 1..10, do: %{"id" => id, "name" => "CI", "event" => "pull_request", "created_at" => "2026-10-08T12:00:00Z"}
            {:ok, %{status: 200, body: %{"workflow_runs" => runs, "total_count" => 10}}}
          else
            {:ok, %{status: 200, body: %{"workflow_runs" => [], "total_count" => 0}}}
          end

        req.url =~ "/actions/runs/" ->
          run_id = req.url |> URI.parse() |> Map.fetch!(:path) |> String.split("/") |> Enum.at(-2) |> String.to_integer()
          {:ok, %{status: 200, body: %{"jobs" => [%{"id" => run_id, "name" => "test"}]}}}

        true ->
          {:error, :unexpected_request}
      end
    end

    sources = %{"required_workflows" => ["CI"], "include_sources" => ["ci_runs", "jobs"]}
    {data, ["github"]} = RunTelemetry.window_event_sources("owner/repo", sources, @range, token: "test-gh-token", request_fun: request)
    jobs = data["jobs"]
    assert length(jobs) == 3
    assert data["jobs_partial"]
  end
end

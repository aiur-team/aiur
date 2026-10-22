defmodule Aiur.LandingWatch.MergeGroupRunFetcherTest do
  use ExUnit.Case, async: true

  alias Aiur.ExecutorSweep.CacheAges
  alias Aiur.GitHub.ResourceStore
  alias Aiur.LandingWatch.MergeGroupRunFetcher

  test "an oversized run page records fresh per-run ages without caching the page body" do
    owner = "aiur-team"
    repo = "merge-group-age-#{System.unique_integer([:positive])}"
    run_id = System.unique_integer([:positive])
    oversized_run = %{"id" => run_id, "event" => "merge_group", "name" => String.duplicate("x", 270_000)}

    request = fn %{method: :get, url: url} ->
      status = URI.parse(url).query |> URI.decode_query() |> Map.fetch!("status")
      runs = if status == "in_progress", do: [oversized_run], else: []
      {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}
    end

    assert {:ok, [^oversized_run]} =
             MergeGroupRunFetcher.active_runs(owner, repo, "main", "test-token", request_fun: request)

    page_key = ResourceStore.key(:landing_merge_group_runs, owner, repo, "main:in_progress:0")
    index_key = ResourceStore.key(:landing_merge_group_runs, owner, repo, "main:in_progress:0:age-index")
    assert :miss = ResourceStore.fetch(page_key)
    assert {:ok, %{data: [%{"id" => ^run_id}]}} = ResourceStore.fetch(index_key)
    assert %{merge_group_runs: %{^run_id => age}} = CacheAges.for_repo(owner, repo)
    assert age < 5 * 60_000
  end
end

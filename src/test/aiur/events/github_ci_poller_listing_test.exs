defmodule Aiur.Events.GithubCIPollerListingTest do
  use Aiur.TestSupport
  import Aiur.TestSupport.CIPollerFixture

  alias Aiur.GitHub.ResourceStore

  setup :ci_poller_env

  test "prefetches one shared branch listing before parallel REST fallbacks" do
    key = ResourceStore.key_for_repo(:branch_pull_request_listing_all, "owner/repo", "open")
    ResourceStore.drop_data(key)
    on_exit(fn -> ResourceStore.drop_data(key) end)

    parent = self()
    etag = ~s("open-prs-v1")

    request_fun = fn %{url: url} = request ->
      cond do
        String.contains?(url, "/pulls?") ->
          send(parent, {:pull_listing, Map.get(request, :etag)})

          case Map.get(request, :etag) do
            nil ->
              {:ok,
               %{
                 status: 200,
                 headers: [{"etag", etag}],
                 body: [
                   %{"number" => 71, "head" => pr_head("aiur/42", "sha-42"), "base" => %{"ref" => "main"}},
                   %{"number" => 72, "head" => pr_head("aiur/43", "sha-43"), "base" => %{"ref" => "main"}}
                 ]
               }}

            ^etag ->
              {:ok, %{status: 304, headers: [{"etag", etag}]}}
          end

        String.contains?(url, "/check-runs?") ->
          {:ok, %{status: 200, body: %{"check_runs" => []}}}

        String.ends_with?(url, "/status") ->
          {:ok, %{status: 200, body: %{"state" => "success", "statuses" => []}}}
      end
    end

    assert {:ok, %{errors: [], results: results}} = poll(["42", "43"], request_fun: request_fun, base_branch: "main")
    assert length(results) == 2
    assert_receive {:pull_listing, nil}, 1000
    assert_receive {:pull_listing, ^etag}, 1000
    assert_receive {:pull_listing, ^etag}, 1000
    refute_receive {:pull_listing, _etag}, 100
  end
end

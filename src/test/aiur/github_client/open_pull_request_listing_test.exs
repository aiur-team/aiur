defmodule Aiur.GitHub.Client.OpenPullRequestListingTest do
  use Aiur.TestSupport

  import Aiur.GitHub.ClientTestSupport

  alias Aiur.GitHub.{Client, CycleFetchCache, ResourceStore}

  setup do
    setup_client()

    keys = [
      ResourceStore.key_for_repo(:branch_pull_request_listing_all, "owner/repo", "open"),
      ResourceStore.key_for_repo(:branch_pull_request_listing, "owner/repo", "35"),
      ResourceStore.key_for_repo(:branch_pull_request_listing, "owner/repo", "36"),
      ResourceStore.key_for_repo(:branch_pull_request_listing, "owner/repo", "37"),
      ResourceStore.key_for_repo(:branch_pull_request, "owner/repo", "35")
    ]

    Enum.each(keys, &ResourceStore.drop_data/1)

    on_exit(fn ->
      CycleFetchCache.end_cycle()
      Enum.each(keys, &ResourceStore.drop_data/1)
    end)
  end

  test "different ticket lookups share one repo listing validator and held result" do
    {:ok, counts} = Agent.start_link(fn -> %{full: 0, conditional: 0} end)
    parent = self()
    etag = ~s("repo-open-pulls-v1")

    request_fun = fn %{method: :get, url: url} = request ->
      assert url =~ "/repos/owner/repo/pulls?"

      case Map.get(request, :etag) do
        nil ->
          Agent.update(counts, &Map.update!(&1, :full, fn count -> count + 1 end))
          send(parent, :full_listing)

          {:ok,
           %{
             status: 200,
             headers: [{"etag", etag}],
             body: [
               %{"number" => 49, "head" => %{"ref" => "aiur/35"}},
               %{"number" => 50, "head" => %{"ref" => "aiur/36-readable-slug"}},
               %{"number" => 51, "head" => %{"ref" => "aiur/37"}}
             ]
           }}

        ^etag ->
          Agent.update(counts, &Map.update!(&1, :conditional, fn count -> count + 1 end))
          send(parent, {:conditional, request.etag})
          {:ok, %{status: 304, headers: [{"etag", etag}]}}

        other ->
          flunk("unexpected listing validator #{inspect(other)}")
      end
    end

    assert {:ok, %{"number" => 49}} = Client.fetch_open_pull_request_for_branch(35, request_fun: request_fun)
    assert {:ok, %{"number" => 50}} = Client.fetch_open_pull_request_for_branch(36, request_fun: request_fun)
    assert {:ok, %{"number" => 51}} = Client.fetch_open_pull_request_for_branch(37, request_fun: request_fun)
    assert_receive :full_listing, 1000
    assert_receive {:conditional, ^etag}, 1000
    assert_receive {:conditional, ^etag}, 1000
    assert Agent.get(counts, & &1) == %{full: 1, conditional: 2}

    assert %{"number" => 49} = ResourceStore.data(ResourceStore.key_for_repo(:branch_pull_request_listing, "owner/repo", "35"))
    assert %{"number" => 50} = ResourceStore.data(ResourceStore.key_for_repo(:branch_pull_request_listing, "owner/repo", "36"))
    assert %{"number" => 51} = ResourceStore.data(ResourceStore.key_for_repo(:branch_pull_request_listing, "owner/repo", "37"))
    assert ResourceStore.data(ResourceStore.key_for_repo(:branch_pull_request, "owner/repo", "35")) == nil
  end
end

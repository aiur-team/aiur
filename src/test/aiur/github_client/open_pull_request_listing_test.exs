defmodule Aiur.GitHub.Client.OpenPullRequestListingTest do
  use Aiur.TestSupport

  import Aiur.GitHub.ClientTestSupport

  alias Aiur.GitHub.{Client, CycleFetchCache, ResourceStore}

  setup do
    setup_client()

    keys = [
      ResourceStore.key_for_repo(:branch_pull_request_listing_all, "owner/repo", "open"),
      ResourceStore.key_for_repo(:branch_pull_request, "owner/repo", "35")
    ]

    Enum.each(keys, &ResourceStore.drop_data/1)

    on_exit(fn ->
      CycleFetchCache.end_cycle()
      Enum.each(keys, &ResourceStore.drop_data/1)
    end)
  end

  test "different ticket lookups share one repo listing validator and held result" do
    webhook_key = ResourceStore.key_for_repo(:branch_pull_request, "owner/repo", "35")
    webhook_pr = %{"number" => 49, "source_marker" => "webhook"}
    version = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    :ok = ResourceStore.put_resource(webhook_key, webhook_pr, source: :webhook, version: version)

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
               %{"number" => 49, "head" => %{"ref" => "aiur/35"}, "updated_at" => version},
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

    assert [%{"number" => 49}, %{"number" => 50}, %{"number" => 51}] =
             ResourceStore.data(ResourceStore.key_for_repo(:branch_pull_request_listing_all, "owner/repo", "open"))

    assert {:ok, %{data: ^webhook_pr, source: :webhook}} = ResourceStore.fetch(webhook_key)
  end

  # Fourteen open pull requests on its-everdred/open-games listed at 262 KiB,
  # over the store's 256 KiB body cap, so the listing was never held and every
  # lookup paid for a full `200`. The held listing keeps what lookups read.
  test "a listing over the store body cap as GitHub sends it is still held and revalidated" do
    parent = self()
    etag = ~s("repo-open-pulls-large")
    templates = Map.new(1..40, &{"template_#{&1}_url", String.duplicate("https://api.github.com/repos/owner/repo/x", 3)})
    repository = Map.merge(templates, %{"full_name" => "owner/repo", "owner" => Map.put(templates, "login", "owner")})

    listed =
      for number <- 1..20 do
        %{
          "number" => number,
          "html_url" => "https://github.com/owner/repo/pull/#{number}",
          "body" => "Fixes ##{number}",
          "_links" => %{"self" => %{"href" => "https://api.github.com/repos/owner/repo/pulls/#{number}"}},
          "diff_url" => "https://github.com/owner/repo/pull/#{number}.diff",
          "head" => %{"ref" => "aiur/#{number}", "sha" => "sha#{number}", "repo" => repository},
          "base" => %{"ref" => "main", "repo" => repository}
        }
      end

    assert byte_size(Jason.encode!(listed)) > 256 * 1024

    request_fun = fn request ->
      case Map.get(request, :etag) do
        nil ->
          send(parent, :full_listing)
          {:ok, %{status: 200, headers: [{"etag", etag}], body: listed}}

        ^etag ->
          send(parent, :conditional)
          {:ok, %{status: 304, headers: [{"etag", etag}]}}
      end
    end

    assert {:ok, pr} = Client.fetch_open_pull_request_for_branch(7, request_fun: request_fun)
    assert %{"number" => 7, "html_url" => "https://github.com/owner/repo/pull/7", "body" => "Fixes #7"} = pr
    assert %{"ref" => "aiur/7", "sha" => "sha7", "repo" => %{"full_name" => "owner/repo", "owner" => %{"login" => "owner"}}} = pr["head"]
    refute Map.has_key?(pr, "_links")
    refute Map.has_key?(pr, "diff_url")
    assert_receive :full_listing, 1000

    CycleFetchCache.end_cycle()

    assert {:ok, %{"number" => 9}} = Client.fetch_open_pull_request_for_branch(9, request_fun: request_fun)
    assert_receive :conditional, 1000
    refute_received :full_listing
  end
end

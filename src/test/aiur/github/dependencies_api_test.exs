defmodule Aiur.GitHub.DependenciesApiTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{DependenciesApi, ResourceStore}

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}
  @dependencies_api_version "2026-03-10"

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      case prev_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo"
    )

    ResourceStore.reset()
    on_exit(&ResourceStore.reset/0)
    :ok
  end

  describe "fetch_blocked_by/2" do
    test "uses the 2026-03-10 api version header and returns blocker list" do
      blockers = [%{"number" => 2}]

      request_fun = fn %{method: :get, url: url, api_version: api_version} ->
        assert url =~ "/issues/5/dependencies/blocked_by"
        assert api_version == @dependencies_api_version
        {:ok, %{status: 200, body: blockers}}
      end

      assert {:ok, ^blockers} = DependenciesApi.fetch_blocked_by(5, request_fun: request_fun)
    end
  end

  describe "fetch_blocking/2" do
    test "fetches issues that issue_number is blocking" do
      blocking = [%{"number" => 10}]

      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/issues/3/dependencies/blocking"
        {:ok, %{status: 200, body: blocking}}
      end

      assert {:ok, ^blocking} = DependenciesApi.fetch_blocking(3, request_fun: request_fun)
    end
  end

  describe "add_dependency/3" do
    test "posts blocker id in request body and returns ok map" do
      response = %{"id" => 1, "blocked_by" => [%{"number" => 8}]}

      request_fun = fn %{method: :post, url: url, body: body, api_version: api_version} ->
        assert url =~ "/issues/5/dependencies/blocked_by"
        assert body == %{"issue_id" => 8}
        assert api_version == @dependencies_api_version
        {:ok, %{status: 201, body: response}}
      end

      assert {:ok, ^response} = DependenciesApi.add_dependency(5, 8, request_fun: request_fun)
    end
  end

  # Acceptance #2326: a dependency mutation issues no confirming read. The
  # mutation records the edge it created, and the next `fetch_blocked_by` for the
  # blocked issue is served from the store with zero upstream calls.
  describe "the edge is served from the store after a mutation" do
    test "a blocked-by list fetched once is served from the store on the next read" do
      blockers = [%{"id" => 80_001, "number" => 80}]

      request_fun = fn %{method: :get, url: url, api_version: api_version} ->
        assert url =~ "/issues/5/dependencies/blocked_by"
        assert api_version == @dependencies_api_version
        {:ok, %{status: 200, body: blockers, headers: [{"etag", ~s("e1")}]}}
      end

      assert {:ok, ^blockers} = DependenciesApi.fetch_blocked_by(5, request_fun: request_fun)

      assert {:ok, ^blockers} =
               DependenciesApi.fetch_blocked_by(5,
                 request_fun: fn _request -> flunk("a held list must be served, not fetched") end
               )
    end

    test "the mutation's own edge is served by the next blocked_by read, with zero confirming calls" do
      blocker = %{"id" => 80_001, "number" => 80, "updated_at" => "2026-06-24T10:00:00Z"}

      request_fun = fn %{method: :post} ->
        {:ok, %{status: 201, body: blocker, headers: []}}
      end

      assert {:ok, ^blocker} = DependenciesApi.add_dependency(7, 80_001, request_fun: request_fun)

      # The confirming read — what `IssueDependencies.declare`'s idempotency
      # check and post-write verification would issue — is served from the store.
      assert {:ok, [^blocker]} =
               DependenciesApi.fetch_blocked_by(7,
                 request_fun: fn _request -> flunk("the confirming read must be served from the store") end
               )
    end

    test "a 304 revalidates the held list without a full read" do
      blockers = [%{"id" => 80_001, "number" => 80}]
      key = ResourceStore.key_for_repo(:issue_blocked_by, "owner/repo", 7)
      ResourceStore.put_resource(key, blockers, source: :fetch, etag: ~s("e1"))

      assert {:ok, ^blockers} =
               DependenciesApi.fetch_blocked_by(7,
                 request_fun: fn %{etag: etag} ->
                   assert etag == ~s("e1")
                   {:ok, %{status: 304, headers: [{"etag", ~s("e1")}]}}
                 end
               )
    end

    test "a delete invalidates the held list so the next read revalidates" do
      key = ResourceStore.key_for_repo(:issue_blocked_by, "owner/repo", 7)
      ResourceStore.put_resource(key, [%{"id" => 80_001, "number" => 80}], source: :fetch, etag: ~s("e1"))

      request_fun = fn %{method: :delete} -> {:ok, %{status: 204, body: ""}} end
      assert {:ok, :removed} = DependenciesApi.remove_dependency(7, 80_001, request_fun: request_fun)

      # The stale entry is gone, so the next read goes upstream rather than
      # serving a list that still names the removed blocker.
      assert ResourceStore.fetch(key) == :miss

      assert {:ok, []} =
               DependenciesApi.fetch_blocked_by(7,
                 request_fun: fn %{method: :get} -> {:ok, %{status: 200, body: [], headers: []}} end
               )
    end
  end

  describe "remove_dependency/3" do
    test "sends the blocker id in the full delete URL and accepts no-content success" do
      request_fun = fn %{method: :delete, url: url, api_version: api_version} = request ->
        assert url == "https://api.github.com/repos/owner/repo/issues/5/dependencies/blocked_by/8"
        assert api_version == @dependencies_api_version
        refute Map.has_key?(request, :body)
        {:ok, %{status: 204, body: ""}}
      end

      assert {:ok, :removed} = DependenciesApi.remove_dependency(5, 8, request_fun: request_fun)
    end
  end
end

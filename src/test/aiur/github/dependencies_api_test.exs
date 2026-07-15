defmodule Aiur.GitHub.DependenciesApiTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.DependenciesApi

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

    test "requests 100 entries, follows Link pagination, and returns quota metadata" do
      reset_at = DateTime.to_unix(~U[2026-01-01 00:01:00Z]) |> Integer.to_string()

      request_fun = fn %{method: :get, url: url, api_version: api_version} ->
        assert api_version == @dependencies_api_version

        if String.contains?(url, "page=2") do
          {:ok,
           %{
             status: 200,
             headers: [
               {"x-ratelimit-remaining", "998"},
               {"x-ratelimit-reset", reset_at}
             ],
             body: [%{"number" => 102}]
           }}
        else
          assert url =~ "/issues/5/dependencies/blocked_by?per_page=100"

          next =
            ~s(<https://api.github.com/repos/owner/repo/issues/5/dependencies/blocked_by?per_page=100&page=2>; rel="next")

          {:ok,
           %{
             status: 200,
             headers: [
               {"link", next},
               {"x-ratelimit-remaining", "999"},
               {"x-ratelimit-reset", reset_at}
             ],
             body: [%{"number" => 101}]
           }}
        end
      end

      assert {:ok, [%{"number" => 101}, %{"number" => 102}], %{remaining: 998, reset_at: "2026-01-01T00:01:00Z"}} =
               DependenciesApi.fetch_blocked_by_with_meta(5, request_fun: request_fun)
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

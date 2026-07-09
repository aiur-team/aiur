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
    test "sends delete request for the dependency" do
      response = %{"id" => 1}

      request_fun = fn %{method: :delete, url: url} ->
        assert url =~ "/issues/5/dependencies/blocked_by"
        {:ok, %{status: 200, body: response}}
      end

      assert {:ok, ^response} = DependenciesApi.remove_dependency(5, 8, request_fun: request_fun)
    end
  end
end

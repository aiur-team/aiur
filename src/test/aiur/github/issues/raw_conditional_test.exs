defmodule Aiur.GitHub.Issues.RawConditionalTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Issues

  @token_cache_key {Aiur.GitHub.Access.Token, :resolved_token}

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
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    :ok
  end

  describe "fetch_issue_raw_conditional/2" do
    test "returns raw map on 200 with the :fetched outcome" do
      raw_body = %{"number" => 5, "title" => "Raw"}

      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/issues/5"
        {:ok, %{status: 200, body: raw_body, headers: []}}
      end

      assert {:ok, ^raw_body, :fetched} = Issues.fetch_issue_raw_conditional(5, request_fun: request_fun)
    end

    test "returns error on non-200 status" do
      request_fun = fn _ -> {:ok, %{status: 404, body: %{"message" => "Not Found"}, headers: []}} end
      assert {:error, _} = Issues.fetch_issue_raw_conditional(999, request_fun: request_fun)
    end

    test "uses an explicit validated repository instead of the configured fallback" do
      request_fun = fn %{url: url} ->
        assert url == "https://api.github.com/repos/explicit/repository/issues/5"
        {:ok, %{status: 200, body: %{}, headers: []}}
      end

      assert {:ok, %{}, _outcome} =
               Issues.fetch_issue_raw_conditional(5,
                 repository: {"explicit", "repository"},
                 request_fun: request_fun
               )
    end

    test "rejects an invalid explicit repository before transport" do
      for repository <- [
            {"owner/repo", "repository"},
            {"owner?query", "repository"},
            {"owner", "repository#fragment"},
            {"owner name", "repository"},
            {"..", "repository"}
          ] do
        assert {:error, :invalid_github_repository} =
                 Issues.fetch_issue_raw_conditional(5,
                   repository: repository,
                   request_fun: fn _request -> flunk("transport must not be called") end
                 )
      end
    end
  end
end

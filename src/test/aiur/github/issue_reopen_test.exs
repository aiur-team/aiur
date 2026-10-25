defmodule Aiur.GitHub.IssueReopenTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{IssueReopen, ResourceStore}

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

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    ResourceStore.reset()
    on_exit(&ResourceStore.reset/0)
    :ok
  end

  test "patches the issue open" do
    parent = self()

    request_fun = fn request ->
      send(parent, {:request, request.method, request.url, request.body})
      {:ok, %{status: 200}}
    end

    assert :ok = IssueReopen.reopen("3846", request_fun: request_fun)
    assert_received {:request, :patch, url, %{"state" => "open"}}
    assert String.ends_with?(url, "/repos/owner/repo/issues/3846")
  end

  test "reports a refused reopen" do
    request_fun = fn _ -> {:ok, %{status: 403, body: %{}, headers: []}} end
    assert {:error, _} = IssueReopen.reopen("3846", request_fun: request_fun)
  end
end

defmodule Aiur.GitHub.IssuesBlockerStampTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Issues

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}

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

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", tracker_label_prefix: "sym")
  end

  test "hydrated blockers carry their fetch time so the dependency gate can age them" do
    blocker = %{"number" => 3, "html_url" => "https://github.com/owner/repo/issues/3", "state" => "open", "labels" => [%{"name" => "sym:todo"}]}
    request_fun = fn %{method: :get} -> {:ok, %{status: 200, body: [blocker]}} end
    before = System.system_time(:millisecond)

    assert {:ok, %Issue{blocked_by: [%{observed_at_ms: at}]}} =
             Issues.hydrate_blocked_by(%Issue{id: "5", identifier: "5", title: "t", state: "todo"}, request_fun: request_fun)

    assert at in before..System.system_time(:millisecond)
  end
end

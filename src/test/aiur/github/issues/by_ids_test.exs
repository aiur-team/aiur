defmodule Aiur.GitHub.Issues.ByIdsTest do
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

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    :ok
  end

  describe "fetch_issue_states_by_ids/2" do
    test "returns empty list for empty id list" do
      assert {:ok, []} = Issues.fetch_issue_states_by_ids([])
    end

    test "fetches issues by numeric id via individual requests" do
      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/issues/42"

        body = %{
          "number" => 42,
          "title" => "Fix bug",
          "body" => "desc",
          "html_url" => "https://github.com/owner/repo/issues/42",
          "labels" => [%{"name" => "sym:in-progress"}],
          "assignee" => %{"login" => "dev"},
          "created_at" => "2026-01-01T00:00:00Z",
          "updated_at" => "2026-01-02T00:00:00Z"
        }

        {:ok, %{status: 200, body: body}}
      end

      assert {:ok, [issue]} =
               Issues.fetch_issue_states_by_ids(["42"], request_fun: request_fun)

      assert issue.id == "42"
      assert issue.assignee_id == "dev"
    end

    test "does not authorize a closed terminal issue during dispatch revalidation" do
      parent = self()

      request_fun = fn %{method: :get, url: url} ->
        if String.contains?(url, "/timeline?per_page=") do
          send(parent, :timeline_requested)
          {:ok, %{status: 200, headers: [], body: []}}
        else
          body = %{
            "number" => 1766,
            "title" => "Already completed",
            "body" => nil,
            "html_url" => "https://github.com/owner/repo/issues/1766",
            "state" => "closed",
            "labels" => [%{"name" => "sym:done"}, %{"name" => "sym:rate-limit-fallback"}],
            "assignee" => nil,
            "created_at" => "2026-01-01T00:00:00Z",
            "updated_at" => "2026-01-02T00:00:00Z"
          }

          {:ok, %{status: 200, body: body}}
        end
      end

      assert {:ok, [issue]} =
               Issues.fetch_issue_states_by_ids(["1766"], request_fun: request_fun)

      assert issue.state == "Closed"
      assert issue.state_labels == ["done"]
      refute_received :timeline_requested
      refute_receive {:alert, %{name: "github.dispatch_authorization.ambiguous"}}, 100
    end
  end
end

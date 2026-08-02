defmodule Aiur.GitHub.IssuesTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{BlockerCache, Issues}

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

    BlockerCache.clear()

    :ok
  end

  describe "fetch_issues_by_states/2" do
    test "returns empty list when no states given" do
      assert {:ok, []} = Issues.fetch_issues_by_states([])
    end

    test "fetches issues for each state label" do
      request_fun = fn %{method: :get, url: url} ->
        if URI.decode(url) =~ "labels=sym:todo" do
          body = [
            %{
              "number" => 7,
              "title" => "A todo issue",
              "body" => nil,
              "html_url" => "https://github.com/owner/repo/issues/7",
              "labels" => [%{"name" => "sym:todo"}],
              "assignee" => nil,
              "created_at" => "2026-01-01T00:00:00Z",
              "updated_at" => "2026-01-02T00:00:00Z"
            }
          ]

          {:ok, %{status: 200, headers: [{"etag", "\"issue-list-v1\""}], body: body}}
        else
          {:ok, %{status: 200, body: []}}
        end
      end

      assert {:ok, [issue]} = Issues.fetch_issues_by_states(["todo"], request_fun: request_fun)
      assert issue.id == "7"
      assert issue.state == "todo"
      assert issue.dispatch_revision == "\"issue-list-v1\""
    end

    test "follows Link rel=next so CI lifecycle states are not silently omitted" do
      issue = fn number ->
        %{
          "number" => number,
          "title" => "CI issue #{number}",
          "body" => nil,
          "html_url" => "https://github.com/owner/repo/issues/#{number}",
          "labels" => [%{"name" => "sym:ci-wait"}],
          "assignee" => nil,
          "created_at" => "2026-01-01T00:00:00Z",
          "updated_at" => "2026-01-02T00:00:00Z"
        }
      end

      request_fun = fn %{method: :get, url: url} ->
        if String.contains?(url, "page=2") do
          {:ok, %{status: 200, headers: [], body: [issue.(200)]}}
        else
          next =
            ~s(<https://api.github.com/repos/owner/repo/issues?labels=sym%3Aci-wait&state=open&per_page=100&page=2>; rel="next")

          {:ok, %{status: 200, headers: [{"link", next}], body: [issue.(100)]}}
        end
      end

      assert {:ok, issues} = Issues.fetch_issues_by_states(["ci-wait"], request_fun: request_fun)
      assert Enum.map(issues, & &1.id) |> MapSet.new() == MapSet.new(["100", "200"])
    end
  end

  describe "fetch_issue_states_by_ids/2" do
    test "returns empty list for empty id list" do
      assert {:ok, []} = Issues.fetch_issue_states_by_ids([])
    end

    test "fetches issues by numeric id via individual requests" do
      request_fun = fn %{method: :get, url: url} ->
        if String.contains?(url, "/dependencies/blocked_by") do
          {:ok, %{status: 200, body: []}}
        else
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
      end

      assert {:ok, [issue]} =
               Issues.fetch_issue_states_by_ids(["42"], request_fun: request_fun)

      assert issue.id == "42"
      assert issue.assignee_id == "dev"
    end

    test "caches blocker hydration across polls" do
      test_pid = self()
      issue = %{"number" => 42, "title" => "Dependent", "body" => "## Acceptance\n- Verify /dev/hidraw0.", "labels" => [%{"name" => "sym:todo"}], "state" => "open"}

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/dependencies/blocked_by") ->
            send(test_pid, :dependency_request)
            {:ok, %{status: 200, body: []}}

          true ->
            {:ok, %{status: 200, body: issue}}
        end
      end

      assert {:ok, [_]} = Issues.fetch_issue_states_by_ids(["42"], request_fun: request_fun, cache_blockers: true, now_ms: 0)
      assert_received :dependency_request
      assert {:ok, [_]} = Issues.fetch_issue_states_by_ids(["42"], request_fun: request_fun, cache_blockers: true, now_ms: 1)
      refute_receive :dependency_request
    end

    test "keeps stale blockers and fails closed only for a dependency hydration error" do
      test_pid = self()

      issue = fn number ->
        %{
          "number" => number,
          "title" => "Dependent #{number}",
          "body" => "Implement the transport.",
          "labels" => [%{"name" => "sym:todo"}],
          "state" => "open"
        }
      end

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/dependencies/blocked_by") and String.contains?(url, "/42/") ->
            send(test_pid, {:dependency_request, "42"})

            if Process.get(:stale_refresh) do
              {:error, :rate_limited}
            else
              {:ok,
               %{
                 status: 200,
                 body: [
                   %{
                     "number" => 41,
                     "title" => "Passing spike",
                     "body" => "## Acceptance\n- Verify /dev/hidraw0.",
                     "labels" => [
                       %{"name" => "sym:operator-verification-required"},
                       %{"name" => "sym:operator-verified"},
                       %{"name" => "sym:operator-verification-passed"}
                     ],
                     "state" => "closed"
                   }
                 ]
               }}
            end

          String.contains?(url, "/dependencies/blocked_by") and String.contains?(url, "/43/") ->
            send(test_pid, {:dependency_request, "43"})
            {:error, :rate_limited}

          String.contains?(url, "/timeline?") ->
            {:ok, %{status: 200, headers: [], body: []}}

          String.ends_with?(url, "/issues/42") ->
            {:ok, %{status: 200, body: issue.(42)}}

          String.ends_with?(url, "/issues/43") ->
            {:ok, %{status: 200, body: issue.(43)}}
        end
      end

      assert {:ok, [_]} =
               Issues.fetch_issue_states_by_ids(["42"],
                 request_fun: request_fun,
                 cache_blockers: true,
                 now_ms: 0
               )

      assert_received {:dependency_request, "42"}
      Process.put(:stale_refresh, true)

      assert {:ok, [stale_issue, failed_issue]} =
               Issues.fetch_issue_states_by_ids(["42", "43"],
                 request_fun: request_fun,
                 cache_blockers: true,
                 now_ms: 30_001
               )

      assert_received {:dependency_request, "42"}
      assert_received {:dependency_request, "43"}
      assert [%{identifier: "41"}] = stale_issue.blocked_by
      assert [%{identifier: ""}] = failed_issue.blocked_by
    end

    test "normalizes native dependency blockers with their verification labels" do
      request_fun = fn %{method: :get, url: url} ->
        if String.contains?(url, "/dependencies/blocked_by") do
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 41,
                 "title" => "Hardware spike",
                 "body" => "Verify /dev/hidraw0 after a replug.",
                 "labels" => [%{"name" => "sym:operator-verification-required"}],
                 "state" => "closed"
               }
             ]
           }}
        else
          {:ok,
           %{
             status: 200,
             body: %{
               "number" => 42,
               "title" => "Dependent",
               "body" => "Implement the transport.",
               "labels" => [%{"name" => "sym:todo"}],
               "state" => "open"
             }
           }}
        end
      end

      assert {:ok, [%{blocked_by: [blocker]}]} =
               Issues.fetch_issue_states_by_ids(["42"], request_fun: request_fun)

      assert blocker.state == "Closed"
      assert blocker.description =~ "/dev/hidraw0"
      assert blocker.labels == ["sym:operator-verification-required"]
    end
  end

  describe "fetch_issue_raw/2" do
    test "returns raw map on 200" do
      raw_body = %{"number" => 5, "title" => "Raw"}

      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/issues/5"
        {:ok, %{status: 200, body: raw_body}}
      end

      assert {:ok, ^raw_body} = Issues.fetch_issue_raw(5, request_fun: request_fun)
    end

    test "returns error on non-200 status" do
      request_fun = fn _ -> {:ok, %{status: 404, body: %{"message" => "Not Found"}}} end
      assert {:error, _} = Issues.fetch_issue_raw(999, request_fun: request_fun)
    end

    test "uses an explicit validated repository instead of the configured fallback" do
      request_fun = fn %{url: url} ->
        assert url == "https://api.github.com/repos/explicit/repository/issues/5"
        {:ok, %{status: 200, body: %{}}}
      end

      assert {:ok, %{}} =
               Issues.fetch_issue_raw(5,
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
                 Issues.fetch_issue_raw(5,
                   repository: repository,
                   request_fun: fn _request -> flunk("transport must not be called") end
                 )
      end
    end
  end

  describe "normalize_issue/4" do
    test "maps github issue fields to Issue struct" do
      gh = %{
        "number" => 10,
        "node_id" => "I_kwDOIssue10",
        "title" => "Test issue",
        "body" => "body text",
        "html_url" => "https://github.com/owner/repo/issues/10",
        "labels" => [%{"name" => "sym:todo"}, %{"name" => "priority:1"}],
        "user" => %{"login" => "creator"},
        "assignee" => %{"login" => "alice"},
        "state" => "open",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      }

      issue = Issues.normalize_issue(gh, "owner", "repo", "sym")

      assert issue.id == "10"

      assert %{
               status: :joinable,
               kind: :github,
               owner: "owner",
               repository: "repo",
               provider_id: "I_kwDOIssue10",
               identifier: "10"
             } =
               issue.tracker_identity

      assert issue.title == "Test issue"
      assert issue.priority == 1
      assert issue.state == "todo"
      assert issue.assignee_id == "alice"
      assert issue.creator_login == "creator"
      refute issue.dispatch_authorized?
      assert issue.paused == false
    end

    test "marks repository-mismatched and missing-node responses explicitly nonjoinable" do
      mismatched = %{
        "number" => 14,
        "node_id" => "I_kwDOIssue14",
        "repository_url" => "https://api.github.com/repos/other/repo",
        "labels" => []
      }

      missing_node = %{"number" => 15, "title" => "Legacy response", "labels" => []}

      assert %{status: :unjoinable, reason: :repository_mismatch} =
               Issues.normalize_issue(mismatched, "owner", "repo", "sym").tracker_identity

      assert %{status: :unjoinable, reason: :missing_provider_identity, identifier: "15"} =
               Issues.normalize_issue(missing_node, "owner", "repo", "sym").tracker_identity
    end

    test "does not use the current checkout when repository configuration is absent" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: nil,
        tracker_label_prefix: "sym"
      )

      issue = %{"number" => 16, "node_id" => "I_kwDOIssue16", "labels" => []}

      assert %{status: :unjoinable, reason: :missing_configured_repository} =
               Issues.normalize_issue(issue, "owner", "repo", "sym").tracker_identity
    end

    test "marks malformed configured repositories explicitly nonjoinable" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo/extra",
        tracker_label_prefix: "sym"
      )

      issue = %{"number" => 17, "node_id" => "I_kwDOIssue17", "labels" => []}

      assert %{status: :unjoinable, reason: :invalid_configured_repository} =
               Issues.normalize_issue(issue, "owner", "repo", "sym").tracker_identity
    end

    test "marks closed issues with Closed state" do
      gh = %{
        "number" => 11,
        "title" => "Closed",
        "body" => nil,
        "html_url" => "https://github.com/owner/repo/issues/11",
        "labels" => [],
        "assignee" => nil,
        "state" => "closed",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      }

      issue = Issues.normalize_issue(gh, "owner", "repo", "sym")
      assert issue.state == "Closed"
    end

    test "marks paused issues" do
      gh = %{
        "number" => 12,
        "title" => "Paused",
        "body" => nil,
        "html_url" => "https://github.com/owner/repo/issues/12",
        "labels" => [%{"name" => "sym:paused"}, %{"name" => "sym:in-progress"}],
        "assignee" => nil,
        "state" => "open",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      }

      issue = Issues.normalize_issue(gh, "owner", "repo", "sym")
      assert issue.paused == true
      assert issue.state == "in-progress"
    end

    test "keeps the fallback marker out of workflow state selection" do
      gh = %{
        "number" => 13,
        "title" => "Fallback",
        "body" => nil,
        "html_url" => "https://github.com/owner/repo/issues/13",
        "labels" => [%{"name" => "sym:rate-limit-fallback"}, %{"name" => "sym:in-progress"}],
        "assignee" => nil,
        "state" => "open",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      }

      issue = Issues.normalize_issue(gh, "owner", "repo", "sym")

      assert issue.state == "in-progress"
      assert "sym:rate-limit-fallback" in issue.labels
    end
  end

  describe "parse_datetime/1" do
    test "returns nil for nil" do
      assert Issues.parse_datetime(nil) == nil
    end

    test "parses ISO 8601 strings" do
      assert %DateTime{year: 2026} = Issues.parse_datetime("2026-01-01T00:00:00Z")
    end
  end
end

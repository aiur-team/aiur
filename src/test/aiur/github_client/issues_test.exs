defmodule Aiur.GitHub.Client.IssuesTest do
  use Aiur.TestSupport

  import Aiur.GitHub.ClientTestSupport

  alias Aiur.GitHub.Client
  alias Aiur.Workflow

  setup do
    setup_client()
  end

  describe "fetch_candidate_issues/1" do
    test "fetches one open snapshot and filters configured active states including rework" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "sym",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"]
      )

      parent = self()

      request_fun = fn %{method: :get, url: url} ->
        decoded_url = URI.decode(url)

        if decoded_url =~ "/timeline" do
          # Dispatch authorization checks trigger-label provenance after fetch.
          {:ok, %{status: 200, body: []}}
        else
          assert decoded_url =~ "/repos/owner/repo/issues?state=open&per_page=100"
          refute decoded_url =~ "labels="
          send(parent, :candidate_request)

          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 35,
                 "title" => "Fix review feedback",
                 "body" => nil,
                 "html_url" => "https://github.com/owner/repo/issues/35",
                 "labels" => [%{"name" => "sym:rework"}],
                 "assignee" => nil,
                 "created_at" => "2026-06-23T00:00:00Z",
                 "updated_at" => "2026-06-23T01:00:00Z"
               },
               %{
                 "number" => 36,
                 "title" => "Waiting for CI",
                 "body" => nil,
                 "html_url" => "https://github.com/owner/repo/issues/36",
                 "labels" => [%{"name" => "sym:ci-wait"}],
                 "assignee" => nil,
                 "created_at" => "2026-06-23T00:00:00Z",
                 "updated_at" => "2026-06-23T01:00:00Z"
               }
             ]
           }}
        end
      end

      assert {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: request_fun)
      assert issue.id == "35"
      assert issue.state == "rework"

      assert_received :candidate_request
      refute_received :candidate_request
    end

    test "surfaces an issue carrying contradictory active-state labels as undispatchable" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "sym",
        tracker_active_states: ["in-progress", "rework"]
      )

      issue = fn ->
        %{
          "number" => 35,
          "title" => "Fix review feedback",
          "body" => nil,
          "html_url" => "https://github.com/owner/repo/issues/35",
          "labels" => [%{"name" => "sym:in-progress"}, %{"name" => "sym:rework"}],
          "assignee" => nil,
          "created_at" => "2026-06-23T00:00:00Z",
          "updated_at" => "2026-06-23T01:00:00Z"
        }
      end

      # The all-open snapshot returns each issue once. Contradictory state
      # labels resolve to a concrete state so no consumer sees a nil disposition
      # (and a stale `agent:ci-wait` can be cleared), but the pair must never
      # authorize dispatch: the ticket stays visible and undispatchable rather
      # than silently dropped from the pool as "no work" (#2366). The pair
      # resolves to the most-outstanding-work label (`rework`), never the
      # alphabetically-first one.
      request_fun = fn %{method: :get} -> {:ok, %{status: 200, body: [issue.()]}} end

      assert {:ok, [candidate]} = Client.fetch_candidate_issues(request_fun: request_fun)
      assert candidate.id == "35"
      assert candidate.state == "rework"
      assert candidate.state_labels == ["in-progress", "rework"]
      assert candidate.dispatch_authorized? == false
    end

    test "returns normalized issues from GitHub API" do
      request_fun = fn %{method: :get, url: url, token: token} ->
        assert token == "test-gh-token"
        assert url =~ "/repos/owner/repo/issues"

        cond do
          url =~ "/timeline" ->
            {:ok, %{status: 200, body: []}}

          URI.decode(url) =~ "/repos/owner/repo/issues?state=open&per_page=100" ->
            assert url =~ "state=open"
            refute URI.decode(url) =~ "labels="

            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "number" => 42,
                   "title" => "Fix the bug",
                   "body" => "Something is broken",
                   "html_url" => "https://github.com/owner/repo/issues/42",
                   "labels" => [
                     %{"name" => "sym:todo"},
                     %{"name" => "priority:1"}
                   ],
                   "assignee" => %{"login" => "dev1"},
                   "created_at" => "2025-01-01T00:00:00Z",
                   "updated_at" => "2025-01-02T00:00:00Z"
                 }
               ]
             }}

          true ->
            assert url =~ "state=open"
            {:ok, %{status: 200, body: []}}
        end
      end

      assert {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: request_fun)
      assert issue.id == "42"
      assert issue.identifier == "42"
      assert issue.title == "Fix the bug"
      assert issue.description == "Something is broken"
      assert issue.state == "todo"
      assert issue.priority == 1
      assert issue.assignee_id == "dev1"
      assert issue.url == "https://github.com/owner/repo/issues/42"
    end

    test "deduplicates issues across labels" do
      request_fun = fn %{method: :get} ->
        {:ok,
         %{
           status: 200,
           body: [
             %{
               "number" => 42,
               "title" => "Dup",
               "body" => nil,
               "html_url" => "https://github.com/owner/repo/issues/42",
               "labels" => [%{"name" => "sym:todo"}],
               "assignee" => nil,
               "created_at" => "2025-01-01T00:00:00Z",
               "updated_at" => "2025-01-01T00:00:00Z"
             }
           ]
         }}
      end

      assert {:ok, [_single]} = Client.fetch_candidate_issues(request_fun: request_fun)
    end

    test "returns error on API failure" do
      request_fun = fn _ ->
        {:ok, %{status: 401}}
      end

      assert {:error, {:github, :auth, %{status: 401}}} =
               Client.fetch_candidate_issues(request_fun: request_fun)
    end

    test "returns error when token is missing" do
      System.delete_env("GITHUB_TOKEN")
      assert {:error, :missing_github_token} = Client.fetch_candidate_issues()
    end
  end

  describe "fetch_issues_by_states/2" do
    test "returns empty list for empty states" do
      assert {:ok, []} = Client.fetch_issues_by_states([])
    end

    test "fetches issues by state labels" do
      request_fun = fn %{method: :get, url: url} ->
        if url =~ "/timeline" do
          {:ok, %{status: 200, body: []}}
        else
          assert url =~ "labels="
          assert url =~ "sym:todo" or url =~ "sym%3Atodo"

          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 1,
                 "title" => "Task",
                 "body" => nil,
                 "html_url" => "https://github.com/owner/repo/issues/1",
                 "labels" => [%{"name" => "sym:todo"}],
                 "assignee" => nil,
                 "created_at" => "2025-01-01T00:00:00Z",
                 "updated_at" => "2025-01-01T00:00:00Z"
               }
             ]
           }}
        end
      end

      assert {:ok, issues} = Client.fetch_issues_by_states(["todo"], request_fun: request_fun)
      assert length(issues) == 1
      assert hd(issues).id == "1"
      assert hd(issues).state == "todo"
    end

    test "marks paused override without treating it as the issue state" do
      request_fun = fn %{method: :get, url: url} ->
        if url =~ "/timeline" do
          {:ok, %{status: 200, body: []}}
        else
          assert url =~ "sym:todo" or url =~ "sym%3Atodo"

          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 2,
                 "title" => "Paused task",
                 "body" => nil,
                 "html_url" => "https://github.com/owner/repo/issues/2",
                 "labels" => [
                   %{"name" => "sym:paused"},
                   %{"name" => "sym:todo"},
                   %{"name" => "priority:1"}
                 ],
                 "assignee" => nil,
                 "created_at" => "2025-01-01T00:00:00Z",
                 "updated_at" => "2025-01-01T00:00:00Z"
               }
             ]
           }}
        end
      end

      assert {:ok, [issue]} = Client.fetch_issues_by_states(["todo"], request_fun: request_fun)
      assert issue.state == "todo"
      assert issue.paused == true
      assert "sym:paused" in issue.labels
    end
  end

  describe "fetch_issue_states_by_ids/2" do
    test "returns empty list for empty ids" do
      assert {:ok, []} = Client.fetch_issue_states_by_ids([])
    end

    test "fetches individual issues by number" do
      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/repos/owner/repo/issues/42"

        {:ok,
         %{
           status: 200,
           body: %{
             "number" => 42,
             "title" => "Issue",
             "body" => "desc",
             "html_url" => "https://github.com/owner/repo/issues/42",
             "labels" => [%{"name" => "sym:in-progress"}],
             "assignee" => nil,
             "created_at" => "2025-01-01T00:00:00Z",
             "updated_at" => "2025-01-01T00:00:00Z"
           }
         }}
      end

      assert {:ok, [issue]} =
               Client.fetch_issue_states_by_ids(["42"], request_fun: request_fun)

      assert issue.id == "42"
      assert issue.state == "in-progress"
    end

    test "closed issues ignore stale active labels" do
      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/repos/owner/repo/issues/491"

        {:ok,
         %{
           status: 200,
           body: %{
             "number" => 491,
             "state" => "closed",
             "title" => "Merged issue",
             "body" => "desc",
             "html_url" => "https://github.com/owner/repo/issues/491",
             "labels" => [%{"name" => "sym:rework"}],
             "assignee" => nil,
             "created_at" => "2025-01-01T00:00:00Z",
             "updated_at" => "2025-01-01T00:00:00Z"
           }
         }}
      end

      assert {:ok, [issue]} =
               Client.fetch_issue_states_by_ids(["491"], request_fun: request_fun)

      assert issue.id == "491"
      assert issue.state == "Closed"
      assert "sym:rework" in issue.labels
    end

    test "skips 404 issues" do
      request_fun = fn _ ->
        {:ok, %{status: 404}}
      end

      assert {:ok, []} = Client.fetch_issue_states_by_ids(["999"], request_fun: request_fun)
    end
  end

  describe "create_comment/3" do
    test "creates a comment on an issue" do
      request_fun = fn %{method: :post, url: url, body: body} ->
        assert url =~ "/repos/owner/repo/issues/42/comments"
        assert body == %{"body" => "Hello!"}
        {:ok, %{status: 201}}
      end

      assert :ok = Client.create_comment("42", "Hello!", request_fun: request_fun)
    end

    test "returns error on failure" do
      request_fun = fn _ -> {:ok, %{status: 403}} end

      assert {:error, {:github, :http, %{status: 403}}} =
               Client.create_comment("42", "Hello!", request_fun: request_fun)
    end
  end
end

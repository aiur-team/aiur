defmodule Aiur.GitHub.ClientTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Client
  alias Aiur.Workflow

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    :ok
  end

  describe "fetch_candidate_issues/1" do
    test "returns normalized issues from GitHub API" do
      request_fun = fn %{method: :get, url: url, token: token} ->
        assert token == "test-gh-token"
        assert url =~ "/repos/owner/repo/issues"
        assert url =~ "state=open"

        # Each label is queried separately; return issue only for sym:todo
        if url =~ "sym:todo" or url =~ "sym%3Atodo" do
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
        else
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

      assert {:error, {:github_api_status, 401}} =
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

      assert {:ok, issues} = Client.fetch_issues_by_states(["todo"], request_fun: request_fun)
      assert length(issues) == 1
      assert hd(issues).id == "1"
      assert hd(issues).state == "todo"
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

      assert {:error, {:github_api_status, 403}} =
               Client.create_comment("42", "Hello!", request_fun: request_fun)
    end
  end

  describe "fetch_pull_request_head_ref/2" do
    test "returns the PR head branch ref" do
      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/repos/owner/repo/pulls/21"
        {:ok, %{status: 200, body: %{"head" => %{"ref" => "aiur/7"}}}}
      end

      assert {:ok, "aiur/7"} = Client.fetch_pull_request_head_ref(21, request_fun: request_fun)
    end

    test "surfaces a non-200 status as an error" do
      request_fun = fn _ -> {:ok, %{status: 404}} end

      assert {:error, {:github_api_status, 404}} =
               Client.fetch_pull_request_head_ref(21, request_fun: request_fun)
    end

    test "errors when the head ref is missing from the payload" do
      request_fun = fn _ -> {:ok, %{status: 200, body: %{"head" => %{}}}} end

      assert {:error, :head_ref_missing} =
               Client.fetch_pull_request_head_ref(21, request_fun: request_fun)
    end
  end

  describe "fetch_classified_pr_review_comments/2" do
    test "labels CODEOWNER review comments authoritative" do
      repo_root = codeowners_repo!("* @owner")

      request_fun = fn %{method: :get, url: url} ->
        cond do
          url =~ "/repos/owner/repo/pulls/7/files" ->
            {:ok, %{status: 200, body: [%{"filename" => "lib/app.ex"}]}}

          url =~ "/repos/owner/repo/pulls/7/comments" ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{"user" => %{"login" => "owner"}, "body" => "Fix this"},
                 %{"user" => %{"login" => "guest"}, "body" => "Maybe fix this"}
               ]
             }}
        end
      end

      assert {:ok, [owner_comment, guest_comment]} =
               Client.fetch_classified_pr_review_comments("7",
                 request_fun: request_fun,
                 repo_root: repo_root
               )

      assert owner_comment.authoritative
      assert owner_comment.authority_reason =~ "CODEOWNER via @owner"
      refute guest_comment.authoritative
      assert guest_comment.authority_reason == "Author is not a CODEOWNER for the relevant paths."

      File.rm_rf!(repo_root)
    end

    test "falls back to authoritative comments when CODEOWNERS is missing" do
      repo_root = Path.join(System.tmp_dir!(), "aiur-github-client-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(repo_root)

      request_fun = fn %{method: :get, url: url} ->
        cond do
          url =~ "/repos/owner/repo/pulls/8/files" ->
            {:ok, %{status: 200, body: [%{"filename" => "lib/app.ex"}]}}

          url =~ "/repos/owner/repo/pulls/8/comments" ->
            {:ok, %{status: 200, body: [%{"user" => %{"login" => "guest"}, "body" => "Fix this"}]}}
        end
      end

      assert {:ok, [comment]} =
               Client.fetch_classified_pr_review_comments(8,
                 request_fun: request_fun,
                 repo_root: repo_root
               )

      assert comment.authoritative
      assert comment.authority_reason == "No CODEOWNERS file found; using compatibility fallback."

      File.rm_rf!(repo_root)
    end
  end

  describe "fetch_classified_issue_comments/2" do
    test "uses repo-wide CODEOWNERS for issue comments without PR paths" do
      repo_root = codeowners_repo!("docs/ @docs-owner\n")

      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/repos/owner/repo/issues/42/comments"

        {:ok,
         %{
           status: 200,
           body: [
             %{"user" => %{"login" => "docs-owner"}, "body" => "Directive"},
             %{"user" => %{"login" => "guest"}, "body" => "Suggestion"}
           ]
         }}
      end

      assert {:ok, [owner_comment, guest_comment]} =
               Client.fetch_classified_issue_comments("42",
                 request_fun: request_fun,
                 repo_root: repo_root
               )

      assert owner_comment.authoritative
      refute guest_comment.authoritative

      File.rm_rf!(repo_root)
    end
  end

  describe "update_issue_state/3" do
    test "swaps labels and closes terminal issues" do
      calls = :ets.new(:calls, [:set, :public])
      :ets.insert(calls, {:count, 0})

      request_fun = fn req ->
        [{:count, n}] = :ets.lookup(calls, :count)
        :ets.insert(calls, {:count, n + 1})

        case {req.method, n} do
          # GET issue
          {:get, 0} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "labels" => [%{"name" => "sym:todo"}, %{"name" => "other"}]
               }
             }}

          # DELETE old label
          {:delete, 1} ->
            assert req.url =~ "sym:todo" or req.url =~ "sym%3Atodo"
            {:ok, %{status: 200}}

          # POST new label
          {:post, 2} ->
            assert req.body == %{"labels" => ["sym:done"]}
            {:ok, %{status: 200}}

          # PATCH close
          {:patch, 3} ->
            assert req.body == %{"state" => "closed"}
            {:ok, %{status: 200}}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      assert :ok = Client.update_issue_state("42", "Done", request_fun: request_fun)
    end
  end

  defp codeowners_repo!(content) do
    repo_root = Path.join(System.tmp_dir!(), "aiur-github-client-test-#{System.unique_integer([:positive])}")
    path = Path.join(repo_root, ".github/CODEOWNERS")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    repo_root
  end
end

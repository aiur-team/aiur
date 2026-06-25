defmodule Aiur.GitHub.ClientTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Client
  alias Aiur.Workflow

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

  describe "fetch_candidate_issues/1" do
    test "fetches configured active state labels including rework" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "sym",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"]
      )

      parent = self()

      request_fun = fn %{method: :get, url: url} ->
        decoded_url = URI.decode(url)

        state =
          cond do
            decoded_url =~ "labels=sym:todo" -> "todo"
            decoded_url =~ "labels=sym:in-progress" -> "in-progress"
            decoded_url =~ "labels=sym:rework" -> "rework"
            decoded_url =~ "labels=sym:merging" -> "merging"
            true -> flunk("unexpected labels query: #{decoded_url}")
          end

        send(parent, {:label_request, state})

        body =
          if state == "rework" do
            [
              %{
                "number" => 35,
                "title" => "Fix review feedback",
                "body" => nil,
                "html_url" => "https://github.com/owner/repo/issues/35",
                "labels" => [%{"name" => "sym:rework"}],
                "assignee" => nil,
                "created_at" => "2026-06-23T00:00:00Z",
                "updated_at" => "2026-06-23T01:00:00Z"
              }
            ]
          else
            []
          end

        {:ok, %{status: 200, body: body}}
      end

      assert {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: request_fun)
      assert issue.id == "35"
      assert issue.state == "rework"

      assert_received {:label_request, "todo"}
      assert_received {:label_request, "in-progress"}
      assert_received {:label_request, "rework"}
      assert_received {:label_request, "merging"}
    end

    test "deduplicates an issue carrying multiple active-state labels" do
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

      # The same issue is returned under both queried labels; the client must
      # collapse it to a single candidate via id-based dedup.
      request_fun = fn %{method: :get} -> {:ok, %{status: 200, body: [issue.()]}} end

      assert {:ok, [deduped]} = Client.fetch_candidate_issues(request_fun: request_fun)
      assert deduped.id == "35"
    end

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

  describe "preflight_auth/1" do
    test "checks rate limit, repository, and issues endpoints with the active token" do
      parent = self()

      request_fun = fn %{method: :get, url: url, token: token} ->
        assert token == "test-gh-token"
        send(parent, {:preflight_url, url})
        {:ok, %{status: 200, headers: [{"x-ratelimit-remaining", "42"}], body: %{}}}
      end

      assert :ok =
               Client.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :not_installed} end
               )

      assert_received {:preflight_url, "https://api.github.com/rate_limit"}
      assert_received {:preflight_url, "https://api.github.com/repos/owner/repo"}
      assert_received {:preflight_url, "https://api.github.com/repos/owner/repo/issues?state=open&per_page=1"}
    end

    test "reports invalid GITHUB_TOKEN without leaking token material" do
      request_fun = fn %{url: url} ->
        if url =~ "/rate_limit" do
          {:ok, %{status: 401, headers: [], body: %{"message" => "Bad credentials"}}}
        else
          flunk("preflight should stop after the failed endpoint")
        end
      end

      assert {:error, {:github_auth_preflight_failed, diagnostic}} =
               Client.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :available} end
               )

      assert diagnostic.reason == :invalid_or_expired_token
      assert diagnostic.endpoint == :rate_limit
      assert diagnostic.status == 401
      assert diagnostic.gh_keyring_status == :available
      assert diagnostic.message =~ "GITHUB_TOKEN"
      assert diagnostic.message =~ "takes precedence over `gh` keyring auth"
      assert diagnostic.message =~ "gh` keyring auth appears usable"
      refute diagnostic.message =~ "test-gh-token"
    end

    test "fails when the REST core rate limit is exhausted" do
      reset = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_unix()

      request_fun = fn %{url: url} ->
        assert url =~ "/rate_limit"

        {:ok,
         %{
           status: 200,
           headers: [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", Integer.to_string(reset)}],
           body: %{"resources" => %{"core" => %{"remaining" => 0}}}
         }}
      end

      assert {:error, {:github_auth_preflight_failed, diagnostic}} =
               Client.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :unavailable} end
               )

      assert diagnostic.reason == :rate_limited
      assert diagnostic.rate_limit_remaining == 0
      assert diagnostic.message =~ "rate limit is exhausted"
      assert diagnostic.message =~ "GITHUB_TOKEN"
    end

    test "distinguishes endpoint-specific forbidden responses" do
      request_fun = fn %{url: url} ->
        cond do
          url =~ "/rate_limit" ->
            {:ok, %{status: 200, headers: [{"x-ratelimit-remaining", "42"}], body: %{}}}

          url =~ "/repos/owner/repo/issues" ->
            {:ok, %{status: 403, headers: [{"x-ratelimit-remaining", "42"}], body: %{"message" => "Resource not accessible by personal access token"}}}

          url =~ "/repos/owner/repo" ->
            {:ok, %{status: 200, headers: [{"x-ratelimit-remaining", "42"}], body: %{}}}
        end
      end

      assert {:error, {:github_auth_preflight_failed, diagnostic}} =
               Client.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :not_installed} end
               )

      assert diagnostic.reason == :forbidden
      assert diagnostic.endpoint == :issues
      assert diagnostic.rate_limit_remaining == 42
      assert diagnostic.message =~ "missing repository permissions"
      assert diagnostic.message =~ "repos/owner/repo/issues?per_page=1"
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

  describe "fetch_open_pull_request_for_branch/2" do
    test "returns the first open PR for the canonical aiur branch" do
      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/repos/owner/repo/pulls?"
        assert url =~ "state=open"
        assert url =~ "head=owner%3Aaiur%2F35"

        {:ok, %{status: 200, body: [%{"number" => 49, "head" => %{"ref" => "aiur/35"}}]}}
      end

      assert {:ok, %{"number" => 49}} =
               Client.fetch_open_pull_request_for_branch(35, request_fun: request_fun)
    end

    test "returns nil when the branch has no open PR" do
      request_fun = fn %{method: :get} -> {:ok, %{status: 200, body: []}} end

      assert {:ok, nil} = Client.fetch_open_pull_request_for_branch("35", request_fun: request_fun)
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

  describe "fetch_unaddressed_pr_review_thread_comments/2" do
    test "returns latest trusted comments from unresolved threads only" do
      repo_root = codeowners_repo!("src/owned.ts @owner\n")

      request_fun = fn
        %{method: :post, url: "https://api.github.com/graphql", body: body} ->
          assert body["query"] =~ "reviewThreads"
          assert body["variables"]["owner"] == "owner"
          assert body["variables"]["repo"] == "repo"
          assert body["variables"]["number"] == 61

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "repository" => %{
                   "pullRequest" => %{
                     "reviewThreads" => %{
                       "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                       "nodes" => [
                         %{
                           "isResolved" => false,
                           "path" => "src/owned.ts",
                           "line" => 10,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(101, "owner", "please fix this")
                             ]
                           }
                         },
                         %{
                           "isResolved" => true,
                           "path" => "src/owned.ts",
                           "line" => 11,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(102, "owner", "resolved already")
                             ]
                           }
                         },
                         %{
                           "isResolved" => false,
                           "path" => "src/owned.ts",
                           "line" => 12,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(103, "owner", "agent answered this"),
                               review_thread_comment(104, "aiur-bot", "addressed")
                             ]
                           }
                         },
                         %{
                           "isResolved" => false,
                           "path" => "src/owned.ts",
                           "line" => 13,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(105, "guest", "not trusted")
                             ]
                           }
                         },
                         %{
                           "isResolved" => false,
                           "path" => "src/owned.ts",
                           "line" => 14,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(106, "owner", "old request"),
                               review_thread_comment(107, "owner", "reviewer follow-up")
                             ]
                           }
                         },
                         %{
                           "isResolved" => false,
                           "path" => "src/owned.ts",
                           "line" => 15,
                           "comments" => %{
                             "nodes" => [
                               review_thread_comment(108, "owner", "wake test, no code changes needed")
                             ]
                           }
                         }
                       ]
                     }
                   }
                 }
               }
             }
           }}
      end

      assert {:ok, comments} =
               Client.fetch_unaddressed_pr_review_thread_comments(61,
                 request_fun: request_fun,
                 repo_root: repo_root,
                 agent_logins: ["aiur-bot"]
               )

      assert Enum.map(comments, & &1["id"]) == [101, 107]
      assert Enum.map(comments, & &1["body"]) == ["please fix this", "reviewer follow-up"]
      assert Enum.all?(comments, & &1.authoritative)

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

    test "closed issues remove stale active labels without adding a new active label" do
      test_pid = self()

      request_fun = fn req ->
        send(test_pid, {:github_request, req})

        case req.method do
          :get ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "closed",
                 "labels" => [
                   %{"name" => "sym:done"},
                   %{"name" => "sym:human-review"},
                   %{"name" => "sym:rework"},
                   %{"name" => "other"}
                 ]
               }
             }}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      assert :ok = Client.update_issue_state("42", "rework", request_fun: request_fun)

      assert_receive {:github_request, %{method: :get}}
      assert_receive {:github_request, %{method: :delete, url: human_review_url}}
      assert_receive {:github_request, %{method: :delete, url: rework_url}}
      refute human_review_url =~ "sym:done"
      refute rework_url =~ "sym:done"
      refute_receive {:github_request, %{method: :post}}, 100
      refute_receive {:github_request, %{method: :patch}}, 100

      assert human_review_url =~ "sym:human-review" or human_review_url =~ "sym%3Ahuman-review"
      assert rework_url =~ "sym:rework" or rework_url =~ "sym%3Arework"
    end

    test "active label add rechecks issue state after stale label removal" do
      test_pid = self()
      calls = :ets.new(:calls, [:set, :public])
      :ets.insert(calls, {:count, 0})

      request_fun = fn req ->
        send(test_pid, {:github_request, req})
        [{:count, n}] = :ets.lookup(calls, :count)
        :ets.insert(calls, {:count, n + 1})

        case {req.method, n} do
          {:get, 0} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [%{"name" => "sym:human-review"}]
               }
             }}

          {:delete, 1} ->
            {:ok, %{status: 200}}

          {:get, 2} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "closed",
                 "labels" => [%{"name" => "sym:done"}, %{"name" => "sym:rework"}]
               }
             }}

          {:delete, 3} ->
            {:ok, %{status: 200}}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      assert :ok = Client.update_issue_state("42", "rework", request_fun: request_fun)

      assert_receive {:github_request, %{method: :get}}
      assert_receive {:github_request, %{method: :delete, url: human_review_url}}
      assert_receive {:github_request, %{method: :get}}
      assert_receive {:github_request, %{method: :delete, url: rework_url}}
      refute human_review_url =~ "sym:done"
      refute rework_url =~ "sym:done"
      refute_receive {:github_request, %{method: :post}}, 100
      refute_receive {:github_request, %{method: :patch}}, 100

      assert human_review_url =~ "sym:human-review" or human_review_url =~ "sym%3Ahuman-review"
      assert rework_url =~ "sym:rework" or rework_url =~ "sym%3Arework"
    end

    test "closed issue active-label cleanup reports delete failures" do
      test_pid = self()

      request_fun = fn req ->
        send(test_pid, {:github_request, req})

        case req.method do
          :get ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "closed",
                 "labels" => [%{"name" => "sym:human-review"}]
               }
             }}

          :delete ->
            {:ok, %{status: 500}}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      assert {:error, {:github_api_status, 500}} =
               Client.update_issue_state("42", "rework", request_fun: request_fun)

      assert_receive {:github_request, %{method: :get}}
      assert_receive {:github_request, %{method: :delete}}
      refute_receive {:github_request, %{method: :post}}, 100
      refute_receive {:github_request, %{method: :patch}}, 100
    end
  end

  describe "classify_error/1 (error taxonomy)" do
    # Operators must be able to tell a DNS/connectivity failure apart from an
    # auth failure to fix flaky GitHub access (#617): a DNS outage and an
    # expired token need different remediation, but both used to flatten into
    # the opaque {:github_api_request, reason} tuple. Each branch below pins a
    # distinct, pattern-matchable classification so callers can route on it.

    test "an :nxdomain transport error classifies as :dns" do
      assert {:github, :dns, detail} =
               Client.classify_error({:error, %Req.TransportError{reason: :nxdomain}})

      assert detail.reason == :nxdomain
    end

    test "a Mint.TransportError :nxdomain also classifies as :dns" do
      # Req wraps Mint, but classification keys off the shared :reason field so
      # either struct surfaces identically.
      assert {:github, :dns, _detail} =
               Client.classify_error({:error, %Mint.TransportError{reason: :nxdomain}})
    end

    test "a :timeout / :closed / :econnrefused transport error classifies as :timeout" do
      for reason <- [:timeout, :closed, :econnrefused] do
        assert {:github, :timeout, %{reason: ^reason}} =
                 Client.classify_error({:error, %Req.TransportError{reason: reason}})
      end
    end

    test "a TLS alert transport error classifies as :tls" do
      assert {:github, :tls, _detail} =
               Client.classify_error({:error, %Req.TransportError{reason: {:tls_alert, {:handshake_failure, "x"}}}})
    end

    test "an HTTP 401 classifies as :auth" do
      assert {:github, :auth, %{status: 401}} =
               Client.classify_error(%{status: 401, headers: [], body: %{}})
    end

    test "an HTTP 403 rate-limit response classifies as :rate_limited" do
      response = %{
        status: 403,
        headers: [{"x-ratelimit-remaining", "0"}, {"retry-after", "42"}],
        body: %{"message" => "API rate limit exceeded"}
      }

      assert {:github, :rate_limited, detail} = Client.classify_error(response)
      assert detail.retry_after == 42
    end

    test "a plain HTTP 403 (no rate-limit signal) classifies as :http" do
      assert {:github, :http, %{status: 403}} =
               Client.classify_error(%{status: 403, headers: [], body: %{}})
    end

    test "an unmapped 5xx status classifies as :http" do
      assert {:github, :http, %{status: 503}} =
               Client.classify_error(%{status: 503, headers: [], body: %{}})
    end
  end

  describe "transport failures surface the taxonomy (not opaque tuples)" do
    test "fetch_repo_events maps an :nxdomain DNS failure to {:github, :dns, _}" do
      request_fun = fn _ -> {:error, %Req.TransportError{reason: :nxdomain}} end

      assert {:error, {:github, :dns, _detail}} =
               Client.fetch_repo_events(request_fun: request_fun, token: "test-gh-token")
    end

    test "create_comment maps a transport timeout to {:github, :timeout, _}" do
      request_fun = fn _ -> {:error, %Req.TransportError{reason: :timeout}} end

      assert {:error, {:github, :timeout, _detail}} =
               Client.create_comment("42", "hi", request_fun: request_fun)
    end
  end

  defp codeowners_repo!(content) do
    repo_root = Path.join(System.tmp_dir!(), "aiur-github-client-test-#{System.unique_integer([:positive])}")
    path = Path.join(repo_root, ".github/CODEOWNERS")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    repo_root
  end

  defp review_thread_comment(id, login, body) do
    %{
      "databaseId" => id,
      "body" => body,
      "createdAt" => "2026-06-25T04:13:21Z",
      "updatedAt" => "2026-06-25T04:13:21Z",
      "url" => "https://github.test/discussion_r#{id}",
      "author" => %{"login" => login}
    }
  end
end

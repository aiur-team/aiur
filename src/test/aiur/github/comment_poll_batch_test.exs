defmodule Aiur.GitHub.CommentPollBatchTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.CommentPollBatch

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")

    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_token) end)
    :ok
  end

  test "batches target issues with per-target headRefName pull request aliases" do
    request_fun = fn %{method: :post, url: url, body: body} ->
      assert url == "https://api.github.com/graphql"
      assert body["query"] =~ "target_0: issueOrPullRequest(number: 42)"
      assert body["query"] =~ ~s(branch_0_0: pullRequests(headRefName: "aiur/42-comment-batch", states: OPEN, orderBy:)
      # The cost claim: aliases only, never a scan of the repository's open PR
      # list (paginated or not).
      refute body["query"] =~ "states: OPEN, after:"
      refute body["query"] =~ ~r/pullRequests\(states:\s*OPEN/
      refute body["query"] =~ ~r/pullRequests\(first:/
      assert body["query"] =~ "orderBy: {field: CREATED_AT, direction: DESC}"
      # Comment tails are read newest-first so a >100-comment target does not
      # overflow into a permanent per-cycle REST fallback.
      refute body["query"] =~ "comments(first: 100)"
      assert body["query"] =~ "comments(last: 100)"
      assert body["variables"] == %{"owner" => "owner", "repo" => "repo"}

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_0" => issue([comment(1, "issue comment")]),
               "branch_0_0" => %{
                 "pageInfo" => %{"hasNextPage" => false},
                 "nodes" => [pull_request(77, "aiur/42-comment-batch", [comment(2, "PR comment")])]
               }
             }
           }
         }
       }}
    end

    assert {:ok, %{"42" => batch}} =
             CommentPollBatch.fetch(["42"],
               request_fun: request_fun,
               branch_names_by_target: %{"42" => "aiur/42-comment-batch"},
               since: %{"42" => "2026-07-30T00:00:00Z"}
             )

    assert [%{"body" => "issue comment"}] = batch.issue_comments
    assert %{"number" => 77, "head" => %{"ref" => "aiur/42-comment-batch"}} = batch.open_pull_request
    assert [%{"body" => "PR comment"}] = batch.pr_issue_comments
    assert batch.review_thread_comments == []
  end

  # The batch reads `comments(last: 100)`, so "more comments exist" is only a
  # problem when more than 100 arrived inside one poll interval. A long-running
  # ticket with 500 comments must stay in the batch, or the savings evaporate on
  # exactly the busiest targets.
  defp overflowing_issue_request_fun(comments) do
    fn %{method: :post} ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_0" =>
                 comments
                 |> issue()
                 |> put_in(["comments", "pageInfo"], %{"hasPreviousPage" => true}),
               "branch_0_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []}
             }
           }
         }
       }}
    end
  end

  test "keeps a target with more than 100 comments when the newest-100 window covers the cursor" do
    request_fun =
      overflowing_issue_request_fun([
        comment(1, "older than cursor", "2026-07-30T11:00:00Z"),
        comment(2, "newer than cursor", "2026-07-30T13:00:00Z")
      ])

    assert {:ok, %{"42" => batch}} =
             CommentPollBatch.fetch(["42"],
               request_fun: request_fun,
               branch_names_by_target: %{"42" => "aiur/42-comment-batch"},
               since: %{"42" => "2026-07-30T12:00:00Z"}
             )

    # Not omitted: the window reaches back past the cursor, so it is complete
    # for the poller's purposes even though older comments exist.
    assert Map.has_key?(batch, :issue_comments)
    assert [%{"body" => "newer than cursor"}] = batch.issue_comments
  end

  test "omits a target when every comment in the window is newer than the cursor" do
    request_fun = overflowing_issue_request_fun([comment(1, "newer than cursor", "2026-07-30T13:00:00Z")])

    assert {:ok, %{"42" => batch}} =
             CommentPollBatch.fetch(["42"],
               request_fun: request_fun,
               branch_names_by_target: %{"42" => "aiur/42-comment-batch"},
               since: %{"42" => "2026-07-30T12:00:00Z"}
             )

    refute Map.has_key?(batch, :issue_comments)
  end

  # Without a cursor the batch cannot bound the window, while the REST path
  # still applies the poller's default `since`. Trusting the raw window would
  # replay a target's whole comment history after an orchestrator restart.
  test "omits a target's comments when no cursor is known" do
    request_fun = overflowing_issue_request_fun([comment(1, "first page", "2026-07-30T12:00:00Z")])

    assert {:ok, %{"42" => batch}} =
             CommentPollBatch.fetch(["42"],
               request_fun: request_fun,
               branch_names_by_target: %{"42" => "aiur/42-comment-batch"}
             )

    refute Map.has_key?(batch, :issue_comments)
  end

  test "omits a target whose legacy branch guess finds no PR so REST can resolve it" do
    request_fun = fn %{method: :post, body: body} ->
      assert body["query"] =~ ~s(branch_0_0: pullRequests(headRefName: "aiur/42", states: OPEN, orderBy:)

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_0" => issue([comment(1, "issue comment")]),
               "branch_0_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []}
             }
           }
         }
       }}
    end

    assert {:ok, batch} = CommentPollBatch.fetch(["42"], request_fun: request_fun)
    refute Map.has_key?(batch, "42")
  end

  test "uses the direct pull request node when the target number is the PR itself" do
    request_fun = fn %{method: :post} ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_0" => pull_request(77, "feature/watched", [comment(3, "watched PR comment")]),
               "branch_0_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []}
             }
           }
         }
       }}
    end

    assert {:ok, %{"77" => batch}} =
             CommentPollBatch.fetch(["77"], request_fun: request_fun, since: %{"77" => "2026-07-30T00:00:00Z"})

    assert %{"number" => 77, "head" => %{"ref" => "feature/watched"}} = batch.open_pull_request
    assert [%{"body" => "watched PR comment"}] = batch.pr_issue_comments
  end

  test "filters the batch window to comments at or after the since cursor" do
    request_fun = fn %{method: :post} ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_0" =>
                 issue([
                   comment(1, "already seen", "2026-07-30T11:00:00Z"),
                   comment(2, "new", "2026-07-30T13:00:00Z")
                 ]),
               "branch_0_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []}
             }
           }
         }
       }}
    end

    assert {:ok, %{"42" => batch}} =
             CommentPollBatch.fetch(["42"],
               request_fun: request_fun,
               branch_names_by_target: %{"42" => "aiur/42-comment-batch"},
               since: %{"42" => "2026-07-30T12:00:00Z"}
             )

    # Without this filter the batch republishes the whole newest-100 window
    # every cycle and leans entirely on publisher dedup.
    assert [%{"body" => "new"}] = batch.issue_comments
  end

  # #1756: the rework gate reads the review decision and the head commit's
  # authored date off the published comment event. The batch is the only place
  # those two facts are fetched, so they must survive normalization.
  test "carries the review decision and head commit date into the pull request payload" do
    request_fun = fn %{method: :post, body: body} ->
      assert body["query"] =~ "reviewDecision"
      assert body["query"] =~ "commits(last: 1) { nodes { commit { committedDate } } }"

      pull_request =
        77
        |> pull_request("aiur/42-comment-batch", [])
        |> Map.put("reviewDecision", "CHANGES_REQUESTED")
        |> Map.put("commits", %{"nodes" => [%{"commit" => %{"committedDate" => "2026-08-10T04:29:00Z"}}]})

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_0" => issue([]),
               "branch_0_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => [pull_request]}
             }
           }
         }
       }}
    end

    assert {:ok, %{"42" => batch}} =
             CommentPollBatch.fetch(["42"],
               request_fun: request_fun,
               branch_names_by_target: %{"42" => "aiur/42-comment-batch"}
             )

    assert batch.open_pull_request["review_decision"] == "CHANGES_REQUESTED"
    assert batch.open_pull_request["head_committed_at"] == "2026-08-10T04:29:00Z"
  end

  test "leaves the review context nil for a pull request with no reviews or commits" do
    request_fun = fn %{method: :post} ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_0" => issue([]),
               "branch_0_0" => %{
                 "pageInfo" => %{"hasNextPage" => false},
                 "nodes" => [pull_request(77, "aiur/42-comment-batch", [])]
               }
             }
           }
         }
       }}
    end

    assert {:ok, %{"42" => batch}} =
             CommentPollBatch.fetch(["42"],
               request_fun: request_fun,
               branch_names_by_target: %{"42" => "aiur/42-comment-batch"}
             )

    assert batch.open_pull_request["review_decision"] == nil
    assert batch.open_pull_request["head_committed_at"] == nil
  end

  defp issue(comments), do: %{"comments" => %{"nodes" => comments}}

  defp pull_request(number, branch, comments) do
    %{
      "number" => number,
      "state" => "OPEN",
      "headRefName" => branch,
      "headRefOid" => "head-#{number}",
      "baseRefName" => "develop",
      "comments" => %{"nodes" => comments},
      "reviewThreads" => %{"nodes" => []}
    }
  end

  defp comment(id, body, created_at \\ "2026-07-30T12:00:00Z") do
    %{
      "databaseId" => id,
      "body" => body,
      "createdAt" => created_at,
      "updatedAt" => created_at,
      "url" => "https://example.test/comments/#{id}",
      "author" => %{"login" => "its-everdred"}
    }
  end
end

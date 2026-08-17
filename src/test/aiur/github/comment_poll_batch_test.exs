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
      assert body["variables"] == %{"owner" => "owner", "repo" => "repo"}

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_0" => issue(),
               "branch_0_0" => %{
                 "pageInfo" => %{"hasNextPage" => false},
                 "nodes" => [pull_request(77, "aiur/42-comment-batch")]
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

    assert %{"number" => 77, "head" => %{"ref" => "aiur/42-comment-batch"}} = batch.open_pull_request
  end

  # The load-bearing cost assertion for #2069. Comments were the batch's largest
  # node contribution and they are now read over conditional REST, where an
  # unchanged list answers 304 and costs nothing. If a `comments` connection
  # ever returns to this query, the poller silently stops using its ETag cache
  # for that target and the steady-state cycle stops being free — so this is
  # asserted on the query text rather than inferred from the result.
  test "never requests comments: they are read over conditional REST instead" do
    request_fun = fn %{method: :post, body: body} ->
      refute body["query"] =~ "comments(last: 100)"
      refute body["query"] =~ "comments(first: 100)"

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_0" => issue(),
               "branch_0_0" => %{
                 "pageInfo" => %{"hasNextPage" => false},
                 "nodes" => [pull_request(77, "aiur/42-comment-batch")]
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

    # The poller reads `:missing` for both and takes the conditional REST path.
    refute Map.has_key?(batch, :issue_comments)
    refute Map.has_key?(batch, :pr_issue_comments)
  end

  # The other half of the cost claim. A branch alias asks for up to five
  # candidate pull requests per branch and up to two branches per target, so
  # attaching `reviewThreads(first: 100) { comments(last: 20) }` to those nodes
  # bought the complete inline-review contents of up to ten pull requests in
  # order to learn one number.
  test "branch alias candidates carry identity only, never review threads" do
    request_fun = fn %{method: :post, body: body} ->
      [_before, branch_section] = String.split(body["query"], "branch_0_0:", parts: 2)
      refute branch_section =~ "reviewThreads"
      assert branch_section =~ "number state headRefName"
      # Review context is identity-cheap and the rework gate needs it, so it
      # stays on the candidate.
      assert branch_section =~ "reviewDecision"

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_0" => issue(),
               "branch_0_0" => %{
                 "pageInfo" => %{"hasNextPage" => false},
                 "nodes" => [pull_request(77, "aiur/42-comment-batch")]
               }
             }
           }
         }
       }}
    end

    assert {:ok, %{"42" => _batch}} =
             CommentPollBatch.fetch(["42"],
               request_fun: request_fun,
               branch_names_by_target: %{"42" => "aiur/42-comment-batch"}
             )
  end

  # An empty list would read as "this pull request has no unaddressed threads"
  # and drop every inline review comment on it. Omitting the key sends the
  # poller to a per-pull-request read for the one PR that actually resolved.
  test "omits review threads for a branch-discovered pull request rather than claiming none" do
    request_fun = fn %{method: :post} ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_0" => issue(),
               "branch_0_0" => %{
                 "pageInfo" => %{"hasNextPage" => false},
                 "nodes" => [pull_request(77, "aiur/42-comment-batch")]
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

    assert %{"number" => 77} = batch.open_pull_request
    refute Map.has_key?(batch, :review_thread_comments)
  end

  # The direct node is not speculative — it is the target itself — so it keeps
  # the full field set and its threads are answered here.
  test "answers review threads for a target that is itself the pull request" do
    request_fun = fn %{method: :post} ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_0" => pull_request(77, "feature/watched"),
               "branch_0_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []}
             }
           }
         }
       }}
    end

    assert {:ok, %{"77" => batch}} = CommentPollBatch.fetch(["77"], request_fun: request_fun)

    assert %{"number" => 77, "head" => %{"ref" => "feature/watched"}} = batch.open_pull_request
    assert batch.review_thread_comments == []
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
               "target_0" => issue(),
               "branch_0_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []}
             }
           }
         }
       }}
    end

    assert {:ok, batch} = CommentPollBatch.fetch(["42"], request_fun: request_fun)
    refute Map.has_key?(batch, "42")
  end

  # #1756: the rework gate reads the review decision and the head commit's
  # authored date off the published comment event. The batch is the only place
  # those two facts are fetched, so they must survive normalization — including
  # on a branch-discovered candidate, whose field set is otherwise minimal.
  test "carries the review decision and head commit date into the pull request payload" do
    request_fun = fn %{method: :post, body: body} ->
      assert body["query"] =~ "reviewDecision"
      assert body["query"] =~ "commits(last: 1) { nodes { commit { committedDate } } }"

      pull_request =
        77
        |> pull_request("aiur/42-comment-batch")
        |> Map.put("reviewDecision", "CHANGES_REQUESTED")
        |> Map.put("commits", %{"nodes" => [%{"commit" => %{"committedDate" => "2026-08-10T04:29:00Z"}}]})

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_0" => issue(),
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
               "target_0" => issue(),
               "branch_0_0" => %{
                 "pageInfo" => %{"hasNextPage" => false},
                 "nodes" => [pull_request(77, "aiur/42-comment-batch")]
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

  # The normalized payload is handed to the poller as the PR object, so the
  # batch's own bookkeeping keys must not leak into it.
  test "strips batch-internal keys from the pull request payload" do
    request_fun = fn %{method: :post} ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "target_0" => pull_request(77, "feature/watched"),
               "branch_0_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []}
             }
           }
         }
       }}
    end

    assert {:ok, %{"77" => batch}} = CommentPollBatch.fetch(["77"], request_fun: request_fun)

    refute Map.has_key?(batch.open_pull_request, :kind)
    refute Map.has_key?(batch.open_pull_request, :threads_included?)
    refute Map.has_key?(batch.open_pull_request, :review_threads)
  end

  defp issue, do: %{}

  defp pull_request(number, branch) do
    %{
      "number" => number,
      "state" => "OPEN",
      "headRefName" => branch,
      "headRefOid" => "head-#{number}",
      "baseRefName" => "develop",
      "reviewThreads" => %{"nodes" => []}
    }
  end
end

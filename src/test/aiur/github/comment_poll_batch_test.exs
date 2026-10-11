defmodule Aiur.GitHub.CommentPollBatchTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{CommentPollBatch, PollSnapshots, ResourceStore}
  import Aiur.GitHub.CommentPollBatchTestSupport

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    ResourceStore.reset()

    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_token) end)
    :ok
  end

  test "writes complete queried review threads back with poll provenance" do
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

    assert {:ok, %{"77" => _batch}} = CommentPollBatch.fetch(["77"], request_fun: request_fun)

    assert {:ok, %{source: :poll, data: %{"complete" => true, "threads" => []}}} =
             ResourceStore.fetch(PollSnapshots.review_threads_key("owner/repo", 77))
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
               branch_names_by_target: %{"42" => "aiur/42-comment-batch"}
             )

    # The poller reads `:missing` for every comment key and takes the conditional
    # REST path. Asserting the exact key set rather than refuting two names is
    # what makes this fail if any comment key comes back: a refute of a name the
    # batch cannot emit passes against every implementation, including a broken
    # one.
    #
    # The cursor window this call used to pass (`since:`) moved with the comment
    # read itself: `Aiur.GitHub.Comments.comment_query/1` owns it now, and
    # `Aiur.GitHub.CommentsTest` asserts it reaches the URL.
    assert batch |> Map.keys() |> Enum.sort() == [:open_pull_request]
  end

  # `branch_pull_request/2` reads `[node | _rest]` of the branch connection and
  # discards the rest, and GitHub permits one open pull request per head/base
  # pair — so four of the five slots were nodes nothing could read. The review
  # *thread* page is `first: 20` — the measured cost lever (#2355, see the
  # moduledoc): a smaller thread page would push every busy pull request onto
  # the paginated fallback each cycle. The *comment* page nested under it is
  # `last: 1` because the only consumer of these threads reads the last comment
  # of unresolved threads and nothing else (#2355).
  test "asks for only the branch pull requests it reads, keeps the thread page, trims the comment page" do
    request_fun = fn %{method: :post, body: body} ->
      assert body["query"] =~ "direction: DESC}, first: 2)"
      refute body["query"] =~ "direction: DESC}, first: 5)"
      assert body["query"] =~ "reviewThreads(first: 20)"
      refute body["query"] =~ "reviewThreads(first: 100)"
      assert body["query"] =~ "comments(last: 1)"
      refute body["query"] =~ "comments(last: 20)"

      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{}}}}}
    end

    assert {:ok, _batch} = CommentPollBatch.fetch(["42"], request_fun: request_fun)
  end

  # #2355 — the load-bearing measurement. Every batch call logs its document,
  # variables, estimated shape cost and GitHub's own `rateLimit { cost }` at
  # debug level, so the before/after of a connection-size change is observable
  # without reading the quota ledger. The transport injects `rateLimit { cost }`
  # on real traffic; the stub includes it here so the measured half is asserted
  # too. The estimate is asserted as a concrete value, not a prefix: the batch
  # shape is deterministic for this fixed target list, so a regression that
  # empties the interpolation or makes `GraphQLCost.estimate/1` return garbage
  # must fail the test rather than pass through unnoticed.
  test "reports the document, variables, and measured points per call at debug level" do
    log =
      capture_log([level: :debug], fn ->
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
                 },
                 "rateLimit" => %{"cost" => 14}
               }
             }
           }}
        end

        assert {:ok, %{"42" => _batch}} =
                 CommentPollBatch.fetch(["42"],
                   request_fun: request_fun,
                   branch_names_by_target: %{"42" => "aiur/42-comment-batch"}
                 )
      end)

    assert log =~ "comment_poll_batch cost report"
    # Deterministic for this single-target document: one thread-bearing alias
    # (reviewThreads(first: 20) { comments(last: 1) }) plus an identity-only
    # branch alias. If the estimate is not called, or returns garbage, these
    # concrete values fail.
    assert log =~ "estimated_points=1"
    assert log =~ "estimated_nodes=45"
    assert log =~ "measured_points=14"
    assert log =~ "variables=%{\"owner\" => \"owner\", \"repo\" => \"repo\"}"
    # The document is the built batch query, so its operation name is in the log.
    assert log =~ "AiurCommentPollBatch"
  end

  # The other half of the cost claim. A branch alias asks for candidate pull
  # requests per branch and up to two branches per target, so attaching
  # `reviewThreads { comments }` to those nodes bought the complete inline-review
  # contents of every candidate in order to learn one number.
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

  # #2707: the comment poll is the only poll that reads an in-progress ticket's
  # PR, so its draft flag feeds poll-side ready_for_review detection. The flag
  # is a scalar on the node the query already selects: no extra call.
  test "carries the pull request draft flag into the payload" do
    request_fun = fn %{method: :post, body: body} ->
      assert body["query"] =~ "isDraft"

      pull_request =
        77
        |> pull_request("aiur/42-comment-batch")
        |> Map.put("isDraft", true)

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

    assert batch.open_pull_request["draft"] == true
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

    # The whole key set, not a list of three names. Naming the keys that must be
    # absent only guards the ones somebody remembered: `:review_threads_page_info`
    # is dropped by the same `Map.drop/2` and was not among them, so a leak of it
    # was uncaught. An exact set fails on any key that starts or stops being
    # stripped.
    assert batch.open_pull_request |> Map.keys() |> Enum.sort() ==
             ["base", "draft", "head", "head_committed_at", "number", "review_decision", "state"]
  end
end

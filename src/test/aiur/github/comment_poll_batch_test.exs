defmodule Aiur.GitHub.CommentPollBatchTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{CommentPollBatch, ResourceStore}

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
  # thread pages stay at their full size: a smaller one would send every busy
  # pull request onto the paginated fallback each cycle, and this document bills
  # 10-11 points per call, not the ~660 a node count suggests.
  test "asks for only the branch pull requests it reads, and keeps the full thread pages" do
    request_fun = fn %{method: :post, body: body} ->
      assert body["query"] =~ "direction: DESC}, first: 2)"
      refute body["query"] =~ "direction: DESC}, first: 5)"
      assert body["query"] =~ "reviewThreads(first: 100)"
      assert body["query"] =~ "comments(last: 20)"

      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{}}}}}
    end

    assert {:ok, _batch} = CommentPollBatch.fetch(["42"], request_fun: request_fun)
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
             ["base", "head", "head_committed_at", "number", "review_decision", "state"]
  end

  # #2265 — the poll pipe reads the store the webhook pipe writes.
  #
  # These assertions are on the **document that is sent**, not on the value that
  # comes back, and that is what makes them mutation-sensitive: a poller that
  # went on issuing its speculative `pullRequests(headRefName:)` discovery for a
  # target a delivery already identified fails `refute query =~ "branch_0_0"`
  # even though every returned value would still be correct. Reverting the
  # store read fails these tests; nothing else here would notice.
  describe "a pull request a webhook delivery already identified" do
    setup do
      ResourceStore.reset()
      on_exit(&ResourceStore.reset/0)
      :ok
    end

    test "is not rediscovered, and its review threads arrive in this batch instead of a second call" do
      deliver_pull_request(42, 77)

      request_fun = fn %{method: :post, body: body} ->
        assert body["query"] =~ "delivered_0: pullRequest(number: 77)"
        # The saving, stated as an absence: three aliases for this target
        # become one. The speculative branch lookups are gone, and so is the
        # `issueOrPullRequest` alias whose only job was to catch a target that
        # is itself a pull request — which a ticket with a delivered branch
        # pull request never is.
        refute body["query"] =~ "branch_0_0"
        refute body["query"] =~ "target_0:"
        # Identity came from the store. Everything a stale answer could
        # mislead the daemon about is still asked of GitHub on this cycle.
        assert body["query"] =~ "reviewThreads(first: 100)"
        assert body["query"] =~ "reviewDecision"

        {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"delivered_0" => pull_request(77, "aiur/42-x")}}}}}
      end

      assert {:ok, %{"42" => batch}} = CommentPollBatch.fetch(["42"], request_fun: request_fun)

      assert %{"number" => 77} = batch.open_pull_request

      # The `review_threads_unaddressed` half of the win. The poller only pays
      # for its own per-pull-request thread read when this key is absent
      # (`GithubCommentsPoller.poll_unaddressed_pr_review_threads/5`), and a
      # branch-discovered target never carries it. A delivered one does.
      assert Map.has_key?(batch, :review_thread_comments)
    end

    test "must have been delivered, not polled, for the store to answer" do
      deliver_pull_request(42, 77, source: :poll)

      request_fun = fn %{method: :post, body: body} ->
        assert body["query"] =~ "branch_0_0"
        refute body["query"] =~ "delivered_0"

        {:ok, %{status: 200, body: %{"data" => %{"repository" => branch_discovery_response()}}}}
      end

      assert {:ok, %{"42" => batch}} = CommentPollBatch.fetch(["42"], request_fun: request_fun)
      assert %{"number" => 77} = batch.open_pull_request
    end

    # #2326: this document parses `reviewThreads { comments { databaseId } }`,
    # so it deposits the comment→thread mapping it read — the map a
    # `pull_request_review_comment` webhook delivery consults before paying for a
    # GraphQL node lookup (`Aiur.Events.GithubWebhook.ThreadResolver`).
    test "deposits the comment→thread mapping the delivery resolver will read" do
      deliver_pull_request(42, 77)

      request_fun = fn %{method: :post} ->
        node =
          pull_request(77, "aiur/42-x")
          |> Map.put("reviewThreads", %{
            "nodes" => [
              %{
                "id" => "PRRT_thread1",
                "isResolved" => false,
                "path" => "src/x.ex",
                "line" => 1,
                "comments" => %{
                  "nodes" => [
                    %{
                      "databaseId" => 9_101,
                      "body" => "inline",
                      "createdAt" => "2026-06-24T12:00:00Z",
                      "updatedAt" => "2026-06-24T12:00:00Z",
                      "url" => "https://example.test/thread/1",
                      "author" => %{"login" => "its-everdred"}
                    }
                  ]
                }
              }
            ]
          })

        {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"delivered_0" => node}}}}}
      end

      assert {:ok, %{"42" => batch}} = CommentPollBatch.fetch(["42"], request_fun: request_fun)
      assert Map.has_key?(batch, :review_thread_comments)

      key = ResourceStore.key_for_repo(:pr_review_comment_thread, "owner/repo", 9_101)
      assert {:ok, %{data: "PRRT_thread1"}} = ResourceStore.fetch(key)
    end

    # Keyed on `fetched_at_ms` — the age of the body — never on
    # `recorded_at_ms`, which every write touches including a bodyless
    # processed-mark (#2174).
    test "is bought again once the held body is older than the freshness bound" do
      deliver_pull_request(42, 77)

      request_fun = fn %{method: :post, body: body} ->
        refute body["query"] =~ "delivered_0"

        {:ok, %{status: 200, body: %{"data" => %{"repository" => branch_discovery_response()}}}}
      end

      assert {:ok, %{"42" => _batch}} =
               CommentPollBatch.fetch(["42"], request_fun: request_fun, delivered_identity_max_age_ms: 0)
    end

    # Closed is exactly the state in which a *newer* pull request may exist for
    # the ticket, so it must not be answered as "this ticket has none".
    test "falls out to the poller's own lookup when GitHub reports it closed" do
      deliver_pull_request(42, 77)

      request_fun = fn %{method: :post} ->
        node = 77 |> pull_request("aiur/42-x") |> Map.put("state", "CLOSED")
        {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"delivered_0" => node}}}}}
      end

      assert {:ok, batch} = CommentPollBatch.fetch(["42"], request_fun: request_fun)
      refute Map.has_key?(batch, "42")
    end
  end

  defp deliver_pull_request(target, number, opts \\ []) do
    :branch_pull_request
    |> ResourceStore.key_for_repo("owner/repo", target)
    |> ResourceStore.put_resource(
      %{"number" => number, "state" => "open", "head" => %{"ref" => "aiur/#{target}-x"}},
      source: Keyword.get(opts, :source, :webhook),
      version: "2026-08-20T00:00:00Z"
    )
  end

  defp branch_discovery_response do
    %{
      "target_0" => issue(),
      "branch_0_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => [pull_request(77, "aiur/42-x")]}
    }
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

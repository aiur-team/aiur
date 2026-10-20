defmodule Aiur.GitHub.CommentPollBatchWebhookIdentifiedTest do
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

  test "omits delivered review threads while keeping strict review context live" do
    deliver_pull_request(42, 77)

    assert :ok =
             PollSnapshots.put_review_threads("owner/repo", 77, [
               %{"id" => "PRRT_resolved", "isResolved" => false, "updatedAt" => "2026-08-21T09:59:00Z"}
             ])

    assert :ok = PollSnapshots.merge_review_thread("owner/repo", 77, %{"id" => "PRRT_resolved", "isResolved" => true, "updatedAt" => "2026-08-21T10:00:00Z"})

    # Capture the document and assert on it after the fetch returns. Asserting
    # inline would raise inside the transport's retry path, turning a real
    # regression into a request-deadline timeout rather than a failed test.
    test_pid = self()

    request_fun = fn %{method: :post, body: body} ->
      send(test_pid, {:query, body["query"]})

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "delivered_0" => pull_request(77, "feature/watched") |> Map.delete("reviewThreads")
             }
           }
         }
       }}
    end

    assert {:ok, %{"42" => batch}} =
             CommentPollBatch.fetch(["42"], request_fun: request_fun)

    assert_received {:query, query}
    assert query =~ "delivered_0: pullRequest(number: 77)"
    refute query =~ "branch_0_0"
    refute query =~ "reviewThreads(first:"
    assert query =~ "reviewDecision"

    assert batch.review_thread_comments == []
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
        assert body["query"] =~ "reviewThreads(first: 20)"
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
end

defmodule Aiur.GitHub.CIPollBatchWebhookIdentifiedTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{CIPollBatch, PollSnapshots, ResourceStore}
  import Aiur.GitHub.CIPollBatchTestSupport

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    ResourceStore.reset()

    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_token) end)
    :ok
  end

  # #2265 — the poll pipe reads the store the webhook pipe writes.
  #
  # Asserted on the document sent, not the value returned: a poller that kept
  # issuing speculative branch discovery for a target a delivery already
  # identified fails `refute query =~ "branch_0_0"` while every returned value
  # stays correct. Reverting the store read fails these; nothing else notices.
  describe "a pull request a webhook delivery already identified" do
    setup do
      ResourceStore.reset()
      on_exit(&ResourceStore.reset/0)
      :ok
    end

    test "is not rediscovered, and its CI verdict is still read from GitHub this cycle" do
      deliver_pull_request(42, 77)

      request_fun = fn %{method: :post, body: body} ->
        assert body["query"] =~ "delivered_0: pullRequest(number: 77)"
        refute body["query"] =~ "branch_0_0"

        # The line this ticket must not cross. Only the *number* came from the
        # store; the rollup, the mergeability and the review decision are all
        # still asked of GitHub, because a CI verdict served from a cache at
        # any age is what `ReadCache.Policy` refuses on purpose.
        assert body["query"] =~ "statusCheckRollup"
        assert body["query"] =~ "isDraft reviewDecision mergeable mergeStateStatus"
        assert body["query"] =~ "timelineItems(itemTypes: [REOPENED_EVENT, READY_FOR_REVIEW_EVENT], last: 100)"

        node = Map.put(pull_request(), "timelineItems", %{"nodes" => [%{"createdAt" => "2026-10-16T07:54:00Z"}]})
        {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"delivered_0" => node}}}}}
      end

      assert {:ok, %{"42" => batch}} = CIPollBatch.fetch(["42"], request_fun: request_fun)

      assert %{"number" => 77, "head" => %{"sha" => "head-77"}, "reopened_at" => "2026-10-16T07:54:00Z"} = batch.pull_request
      assert [%{"name" => "test", "conclusion" => "success"}] = batch.check_runs
    end

    test "must have been delivered, not polled, for the store to answer" do
      deliver_pull_request(42, 77, source: :poll)

      request_fun = fn %{method: :post, body: body} ->
        assert body["query"] =~ "branch_0_0"
        refute body["query"] =~ "delivered_0"

        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "repository" => %{
                 "branch_0_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => [pull_request()]}
               }
             }
           }
         }}
      end

      assert {:ok, %{"42" => _batch}} =
               CIPollBatch.fetch(["42"], request_fun: request_fun, branch_names_by_target: %{"42" => "aiur/42-ci-batch"})
    end

    # Keyed on `fetched_at_ms` — the age of the body — never `recorded_at_ms`,
    # which every write touches including a bodyless processed-mark (#2174).
    test "is bought again once the held body is older than the freshness bound" do
      deliver_pull_request(42, 77)

      request_fun = fn %{method: :post, body: body} ->
        refute body["query"] =~ "delivered_0"

        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "repository" => %{
                 "branch_0_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => [pull_request()]}
               }
             }
           }
         }}
      end

      assert {:ok, %{"42" => _batch}} =
               CIPollBatch.fetch(["42"],
                 request_fun: request_fun,
                 branch_names_by_target: %{"42" => "aiur/42-ci-batch"},
                 delivered_identity_max_age_ms: 0
               )
    end

    test "leaves the target to REST fallback when GitHub reports it closed" do
      deliver_pull_request(42, 77)

      request_fun = fn %{method: :post} ->
        node = Map.put(pull_request(), "state", "CLOSED")
        {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"delivered_0" => node}}}}}
      end

      assert {:ok, batch} = CIPollBatch.fetch(["42"], request_fun: request_fun)
      refute Map.has_key?(batch, "42")
    end
  end
end

defmodule Aiur.GitHub.CIPollBatchTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{CIPollBatch, PollSnapshots, ResourceStore}

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    ResourceStore.reset()

    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_token) end)
    :ok
  end

  test "queries per-target headRefName aliases and normalizes check runs and legacy statuses" do
    request_fun = fn %{method: :post, url: url, body: body} ->
      assert url == "https://api.github.com/graphql"
      assert body["query"] =~ "query AiurCIPollBatch"
      assert body["query"] =~ ~s(branch_0_0: pullRequests(headRefName: "aiur/42-ci-batch", states: OPEN, orderBy:)
      # The cost claim: aliases only, never a scan of the repository's open PR
      # list (paginated or not).
      refute body["query"] =~ "states: OPEN, after:"
      refute body["query"] =~ ~r/pullRequests\(states:\s*OPEN/
      refute body["query"] =~ ~r/pullRequests\(first:/
      assert body["query"] =~ "orderBy: {field: CREATED_AT, direction: DESC}"

      # Merge-queue recovery observation is part of the same batch node, so
      # the parked-ready decision never pays a separate read.
      assert body["query"] =~ "isDraft reviewDecision mergeable mergeStateStatus"
      assert body["query"] =~ "autoMergeRequest { enabledAt }"
      assert body["query"] =~ "mergeQueueEntry { id }"

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "branch_0_0" => %{
                 "pageInfo" => %{"hasNextPage" => false},
                 "nodes" => [pull_request()]
               }
             }
           }
         }
       }}
    end

    assert {:ok, %{"42" => batch}} =
             CIPollBatch.fetch(["42"],
               request_fun: request_fun,
               branch_names_by_target: %{"42" => "aiur/42-ci-batch"}
             )

    assert %{"number" => 77, "head" => %{"sha" => "head-77"}} = batch.pull_request
    # The batch carries the merge-queue recovery observation derived from the
    # same node, without any extra read.
    assert %{
             "merge_queue" => %{
               draft?: true,
               review_decision: "APPROVED",
               mergeable: "MERGEABLE",
               merge_state_status: "BLOCKED",
               auto_merge_request: nil,
               merge_queue_entry: nil
             }
           } = batch.pull_request

    assert [%{"name" => "test", "status" => "completed", "conclusion" => "success"}] = batch.check_runs
    assert %{"state" => "success", "statuses" => [%{"context" => "legacy", "state" => "success"}]} = batch.commit_status
  end

  test "omits delivery-fresh check runs while retaining live legacy statuses and strict pull request fields" do
    deliver_pull_request(42, 77)

    assert :ok =
             PollSnapshots.put_ci_contexts(
               "owner/repo",
               "42",
               "head-77",
               [%{"id" => 501, "name" => "cached", "status" => "queued", "conclusion" => nil}],
               %{"state" => "failure", "statuses" => [%{"context" => "legacy", "state" => "failure"}]}
             )

    assert :ok =
             PollSnapshots.merge_check_run(
               "owner/repo",
               "42",
               "head-77",
               %{"id" => 501, "name" => "cached", "status" => "completed", "conclusion" => "success", "completed_at" => "2026-08-21T10:01:00Z"}
             )

    request_fun = fn %{method: :post, body: body} ->
      assert body["query"] =~ "delivered_0: pullRequest(number: 77)"
      refute body["query"] =~ "branch_0_0"
      assert body["query"] =~ "isDraft reviewDecision mergeable mergeStateStatus"
      assert body["query"] =~ "status {"
      assert body["query"] =~ "contexts { context state"
      refute body["query"] =~ "statusCheckRollup"
      refute body["query"] =~ "... on CheckRun"
      refute body["query"] =~ "databaseId name status conclusion"

      node = pull_request_with_legacy_status()

      {:ok,
       %{
         status: 200,
         body: %{"data" => %{"repository" => %{"delivered_0" => node}}}
       }}
    end

    assert {:ok, %{"42" => batch}} =
             CIPollBatch.fetch(["42"], request_fun: request_fun)

    assert [%{"name" => "cached", "status" => "completed", "conclusion" => "success"}] = batch.check_runs
    assert %{"state" => "success", "statuses" => [%{"context" => "legacy", "state" => "success"}]} = batch.commit_status
  end

  test "writes a complete polled CI selection back for later webhook advancement" do
    request_fun = fn %{method: :post} ->
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
               branch_names_by_target: %{"42" => "aiur/42-ci-batch"}
             )

    assert :miss = PollSnapshots.ci_contexts("owner/repo", "42")

    assert :ok =
             PollSnapshots.merge_check_run(
               "owner/repo",
               "42",
               "head-77",
               %{"id" => 501, "name" => "test", "status" => "completed", "conclusion" => "failure", "completed_at" => "2026-08-21T10:02:00Z"}
             )

    assert {:ok, %{"check_runs" => [%{"id" => 501, "conclusion" => "failure"}]}} = PollSnapshots.ci_contexts("owner/repo", "42")
  end

  test "a poll-only snapshot does not suppress check-run fields" do
    assert :ok =
             PollSnapshots.put_ci_contexts(
               "owner/repo",
               "42",
               "head-77",
               [%{"id" => 501, "status" => "completed", "conclusion" => "failure"}],
               %{"state" => "failure", "statuses" => []}
             )

    request_fun = fn %{method: :post, body: body} ->
      assert body["query"] =~ "... on CheckRun { databaseId name status conclusion"
      ci_response(pull_request())
    end

    assert {:ok, %{"42" => _batch}} =
             CIPollBatch.fetch(["42"],
               request_fun: request_fun,
               branch_names_by_target: %{"42" => "aiur/42-ci-batch"}
             )
  end

  test "an expired delivery snapshot restores the full check-run selection" do
    deliver_pull_request(42, 77)

    assert :ok =
             PollSnapshots.put_ci_contexts(
               "owner/repo",
               "42",
               "head-77",
               [%{"id" => 501, "status" => "queued", "conclusion" => nil}],
               %{"state" => "pending", "statuses" => []}
             )

    assert :ok =
             PollSnapshots.merge_check_run(
               "owner/repo",
               "42",
               "head-77",
               %{"id" => 501, "status" => "completed", "conclusion" => "success", "completed_at" => "2026-08-21T10:01:00Z"}
             )

    assert {:ok, %{fetched_at_ms: fetched_at_ms}} = ResourceStore.fetch(PollSnapshots.ci_contexts_key("owner/repo", "42"))

    request_fun = fn %{method: :post, body: body} ->
      assert body["query"] =~ "... on CheckRun { databaseId name status conclusion"
      ci_response(pull_request_with_legacy_status(), "delivered_0")
    end

    assert {:ok, %{"42" => _batch}} =
             CIPollBatch.fetch(["42"], request_fun: request_fun, now_ms: fetched_at_ms + 30_001)
  end

  test "a delivery snapshot for an older head leaves the target to exact fallback" do
    deliver_pull_request(42, 77)

    assert :ok =
             PollSnapshots.put_ci_contexts(
               "owner/repo",
               "42",
               "old-head",
               [%{"id" => 501, "status" => "queued", "conclusion" => nil}],
               %{"state" => "pending", "statuses" => []}
             )

    assert :ok =
             PollSnapshots.merge_check_run(
               "owner/repo",
               "42",
               "old-head",
               %{"id" => 501, "status" => "completed", "conclusion" => "success", "completed_at" => "2026-08-21T10:01:00Z"}
             )

    request_fun = fn %{method: :post, body: body} ->
      refute body["query"] =~ "... on CheckRun"
      ci_response(pull_request_with_legacy_status(), "delivered_0")
    end

    assert {:ok, %{}} = CIPollBatch.fetch(["42"], request_fun: request_fun)
  end

  # Regression guard: GitHub issues have no branch name, so without the
  # title-derived candidate every target guesses the legacy `aiur/<id>` branch,
  # misses the real `aiur/<id>-<slug>` one, drops out of the batch, and the
  # daemon pays a GraphQL call ON TOP OF the unchanged REST fan-out.
  test "queries the title-derived branch as well as the legacy one" do
    request_fun = fn %{method: :post, body: body} ->
      assert body["query"] =~ ~s(branch_0_0: pullRequests(headRefName: "aiur/42-daemon-read-budget-conditional")
      assert body["query"] =~ ~s(branch_0_1: pullRequests(headRefName: "aiur/42")

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "branch_0_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => [pull_request()]},
               "branch_0_1" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []}
             }
           }
         }
       }}
    end

    assert {:ok, %{"42" => batch}} =
             CIPollBatch.fetch(["42"],
               request_fun: request_fun,
               titles_by_target: %{"42" => "Daemon read-budget: conditional requests, GraphQL-batched fan-outs"}
             )

    assert %{"number" => 77} = batch.pull_request
  end

  test "falls back to the legacy branch alias when the title-derived one has no PR" do
    request_fun = fn %{method: :post} ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "branch_0_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []},
               "branch_0_1" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => [pull_request()]}
             }
           }
         }
       }}
    end

    assert {:ok, %{"42" => batch}} =
             CIPollBatch.fetch(["42"], request_fun: request_fun, titles_by_target: %{"42" => "Some legacy ticket"})

    assert %{"number" => 77} = batch.pull_request
  end

  test "falls back to the legacy branch name when orchestration knows no branch" do
    request_fun = fn %{method: :post, body: body} ->
      assert body["query"] =~ ~s(branch_0_0: pullRequests(headRefName: "aiur/42", states: OPEN, orderBy:)

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "branch_0_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []}
             }
           }
         }
       }}
    end

    # A missing legacy-branch match is inconclusive (the ticket may use a
    # suffixed branch), so the target is omitted for the REST fallback.
    assert {:ok, batch} = CIPollBatch.fetch(["42"], request_fun: request_fun)
    refute Map.has_key?(batch, "42")
  end

  test "records the absence of an open PR when the branch name is known" do
    request_fun = fn %{method: :post} ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "branch_0_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []}
             }
           }
         }
       }}
    end

    assert {:ok, %{"42" => batch}} =
             CIPollBatch.fetch(["42"],
               request_fun: request_fun,
               branch_names_by_target: %{"42" => "aiur/42-known-branch"}
             )

    assert batch.pull_request == nil
    assert batch.check_runs == []
  end

  test "omits a target whose status contexts overflow so REST can read them completely" do
    request_fun = fn %{method: :post} ->
      overflowed =
        pull_request()
        |> put_in(
          ["commits", "nodes", Access.at(0), "commit", "statusCheckRollup", "contexts", "pageInfo"],
          %{"hasNextPage" => true, "endCursor" => "next"}
        )

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "branch_0_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => [overflowed]}
             }
           }
         }
       }}
    end

    assert {:ok, batch} =
             CIPollBatch.fetch(["42"],
               request_fun: request_fun,
               branch_names_by_target: %{"42" => "aiur/42-ci-batch"}
             )

    refute Map.has_key?(batch, "42")
  end

  # `put_first_pull_request/3` reads `List.first/1` of the branch connection and
  # discards the rest, and GitHub permits one open pull request per head/base
  # pair — so four of the five slots were nodes nothing could read. The status
  # context page is a different matter and stays at 100: shrinking it would send
  # a pull request with many checks to the REST fallback every cycle, and this
  # document bills one point per call.
  test "asks for only the branch pull requests it reads, and keeps the full context page" do
    request_fun = fn %{body: body} ->
      assert body["query"] =~ "direction: DESC}, first: 2)"
      refute body["query"] =~ "direction: DESC}, first: 5)"
      assert body["query"] =~ "contexts(first: 100)"

      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{}}}}}
    end

    assert {:ok, _batch} = CIPollBatch.fetch(["42"], request_fun: request_fun)
  end

  test "does not query GitHub without CI targets" do
    request_fun = fn _request -> flunk("empty target batch must not make a request") end

    assert {:ok, %{}} = CIPollBatch.fetch([], request_fun: request_fun)
  end

  defp ci_response(node, alias_name \\ "branch_0_0") do
    value =
      if String.starts_with?(alias_name, "branch_") do
        %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => [node]}
      else
        node
      end

    {:ok, %{status: 200, body: %{"data" => %{"repository" => %{alias_name => value}}}}}
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

        {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"delivered_0" => pull_request()}}}}}
      end

      assert {:ok, %{"42" => batch}} = CIPollBatch.fetch(["42"], request_fun: request_fun)

      assert %{"number" => 77, "head" => %{"sha" => "head-77"}} = batch.pull_request
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

  defp deliver_pull_request(target, number, opts \\ []) do
    :branch_pull_request
    |> ResourceStore.key_for_repo("owner/repo", target)
    |> ResourceStore.put_resource(
      %{"number" => number, "state" => "open", "head" => %{"ref" => "aiur/#{target}-ci-batch"}},
      source: Keyword.get(opts, :source, :webhook),
      version: "2026-08-20T00:00:00Z"
    )
  end

  defp pull_request do
    %{
      "number" => 77,
      "state" => "OPEN",
      "headRefName" => "aiur/42-ci-batch",
      "headRefOid" => "head-77",
      "baseRefName" => "develop",
      "isDraft" => true,
      "reviewDecision" => "APPROVED",
      "mergeable" => "MERGEABLE",
      "mergeStateStatus" => "BLOCKED",
      "autoMergeRequest" => nil,
      "mergeQueueEntry" => nil,
      "commits" => %{
        "nodes" => [
          %{
            "commit" => %{
              "statusCheckRollup" => %{
                "contexts" => %{
                  "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                  "nodes" => [
                    %{
                      "__typename" => "CheckRun",
                      "databaseId" => 501,
                      "name" => "test",
                      "status" => "COMPLETED",
                      "conclusion" => "SUCCESS",
                      "startedAt" => "2026-07-30T12:00:00Z",
                      "completedAt" => "2026-07-30T12:01:00Z",
                      "output" => %{"summary" => "green", "text" => ""}
                    },
                    %{
                      "__typename" => "StatusContext",
                      "context" => "legacy",
                      "state" => "SUCCESS",
                      "createdAt" => "2026-07-30T12:01:00Z",
                      "description" => "green"
                    }
                  ]
                }
              }
            }
          }
        ]
      }
    }
  end

  defp pull_request_with_legacy_status do
    put_in(pull_request(), ["commits", "nodes"], [
      %{
        "commit" => %{
          "status" => %{
            "contexts" => [
              %{
                "context" => "legacy",
                "state" => "SUCCESS",
                "createdAt" => "2026-07-30T12:01:00Z",
                "description" => "green"
              }
            ]
          }
        }
      }
    ])
  end
end

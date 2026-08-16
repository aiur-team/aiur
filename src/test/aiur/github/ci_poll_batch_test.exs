defmodule Aiur.GitHub.CIPollBatchTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.CIPollBatch

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")

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

  test "does not query GitHub without CI targets" do
    request_fun = fn _request -> flunk("empty target batch must not make a request") end

    assert {:ok, %{}} = CIPollBatch.fetch([], request_fun: request_fun)
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
end

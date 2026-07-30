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
      assert body["query"] =~ ~s(branch_0: pullRequests(headRefName: "aiur/42-ci-batch", states: OPEN)
      refute body["query"] =~ "states: OPEN, after:"

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "branch_0" => %{
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
    assert [%{"name" => "test", "status" => "completed", "conclusion" => "success"}] = batch.check_runs
    assert %{"state" => "success", "statuses" => [%{"context" => "legacy", "state" => "success"}]} = batch.commit_status
  end

  test "falls back to the legacy branch name when orchestration knows no branch" do
    request_fun = fn %{method: :post, body: body} ->
      assert body["query"] =~ ~s(branch_0: pullRequests(headRefName: "aiur/42", states: OPEN)

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "branch_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []}
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
               "branch_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []}
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
               "branch_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => [overflowed]}
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

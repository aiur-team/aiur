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

  test "normalizes check runs and legacy statuses for matching ticket branches" do
    request_fun = fn %{method: :post, url: url, body: body} ->
      assert url == "https://api.github.com/graphql"
      assert body["query"] =~ "query AiurCIPollBatch"

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "pullRequests" => %{
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                 "nodes" => [pull_request()]
               }
             }
           }
         }
       }}
    end

    assert {:ok, %{"42" => batch}} = CIPollBatch.fetch(["42"], request_fun: request_fun)
    assert %{"number" => 77, "head" => %{"sha" => "head-77"}} = batch.pull_request
    assert [%{"name" => "test", "status" => "completed", "conclusion" => "success"}] = batch.check_runs
    assert %{"state" => "success", "statuses" => [%{"context" => "legacy", "state" => "success"}]} = batch.commit_status
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

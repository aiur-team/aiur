defmodule Aiur.GitHub.CommentPollBatchTestSupport do
  @moduledoc "Fixtures shared by the comment poll batch tests."

  alias Aiur.GitHub.ResourceStore

  def deliver_pull_request(target, number, opts \\ []) do
    :branch_pull_request
    |> ResourceStore.key_for_repo("owner/repo", target)
    |> ResourceStore.put_resource(
      %{"number" => number, "state" => "open", "head" => %{"ref" => "aiur/#{target}-x"}},
      source: Keyword.get(opts, :source, :webhook),
      version: "2026-08-20T00:00:00Z"
    )
  end

  def branch_discovery_response do
    %{
      "target_0" => issue(),
      "branch_0_0" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => [pull_request(77, "aiur/42-x")]}
    }
  end

  def issue, do: %{}

  def pull_request(number, branch) do
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

defmodule Aiur.GitHub.CIPollBatchTestSupport do
  @moduledoc "Fixtures shared by the CI poll batch tests."

  import ExUnit.Assertions

  alias Aiur.GitHub.{PollSnapshots, ResourceStore}

  def ci_response(node, alias_name \\ "branch_0_0") do
    value =
      if String.starts_with?(alias_name, "branch_") do
        %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => [node]}
      else
        node
      end

    {:ok, %{status: 200, body: %{"data" => %{"repository" => %{alias_name => value}}}}}
  end

  # Seeds a complete `:ci_contexts` snapshot the way a poll followed by a
  # delivery would leave it: a complete polled baseline advanced by a webhook
  # check-run delivery on the same head.
  def deliver_ci_contexts(target, head_sha, run_id) do
    assert :ok =
             PollSnapshots.put_ci_contexts(
               "owner/repo",
               target,
               head_sha,
               [%{"id" => run_id, "name" => "test", "status" => "queued", "conclusion" => nil}],
               %{"state" => "pending", "statuses" => []}
             )

    assert :ok =
             PollSnapshots.merge_check_run(
               "owner/repo",
               target,
               head_sha,
               %{"id" => run_id, "name" => "test", "status" => "completed", "conclusion" => "success", "completed_at" => "2026-08-21T10:01:00Z"}
             )
  end

  def deliver_pull_request(target, number, opts \\ []) do
    :branch_pull_request
    |> ResourceStore.key_for_repo("owner/repo", target)
    |> ResourceStore.put_resource(
      %{"number" => number, "state" => "open", "head" => %{"ref" => "aiur/#{target}-ci-batch"}},
      source: Keyword.get(opts, :source, :webhook),
      version: "2026-08-20T00:00:00Z"
    )
  end

  def pull_request do
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
                      "checkSuite" => %{"id" => "suite-501", "app" => %{"databaseId" => 15_368}},
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

  def pull_request_with_legacy_status do
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

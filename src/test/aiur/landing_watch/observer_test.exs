defmodule Aiur.LandingWatch.ObserverTest do
  use Aiur.TestSupport

  alias Aiur.LandingWatch.Observer

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "observation maps current approval, queue identity, and required check runs" do
    request = fn request ->
      cond do
        is_binary(request[:url]) and String.contains?(request[:url], "/pulls?") ->
          {:ok, %{status: 200, body: [%{"number" => 17, "head" => %{"ref" => "aiur/17-work"}}], headers: []}}

        is_map(request[:body]) and is_binary(request[:body]["query"]) ->
          query = request[:body]["query"]
          assert query =~ "AiurLandingWatch"

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "repository" => %{
                   "pr_0" => %{
                     "id" => "PR_17",
                     "state" => "OPEN",
                     "headRefOid" => "head-17",
                     "baseRefName" => "main",
                     "isDraft" => false,
                     "reviewDecision" => "APPROVED",
                     "mergeable" => "MERGEABLE",
                     "mergeStateStatus" => "CLEAN",
                     "mergeQueueEntry" => %{"id" => "entry-17"},
                     "autoMergeRequest" => nil,
                     "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "head-17"}}]},
                     "commits" => %{
                       "nodes" => [
                         %{"commit" => %{"committedDate" => "2026-10-14T00:00:00Z"}}
                       ]
                     }
                   }
                 }
               }
             }
           }}

        true ->
          flunk("unexpected request #{inspect(request)}")
      end
    end

    assert {:ok, [pr]} = Observer.observe(token: "test-gh-token", request_fun: request)
    assert pr.number == 17
    assert pr.head == "head-17"
    assert pr.head_committed_at == "2026-10-14T00:00:00Z"
    assert pr.merge_queue_entry == %{"id" => "entry-17"}
  end

  test "approval revalidation requires the exact current head" do
    base_request = fn graphql_request ->
      query = graphql_request[:body]["query"]
      assert query =~ "headRefOid"
      assert query =~ "mergeQueueEntry"

      {:ok,
       %{
         status: 200,
         body: %{"data" => %{"repository" => %{"pullRequest" => %{"headRefOid" => "new-head", "reviewDecision" => "APPROVED", "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "new-head"}}]}}}}}
       }}
    end

    assert {:error, :approval_or_head_changed} = Observer.revalidate_approved_head(17, "old-head", token: "test-gh-token", request_fun: base_request)
    assert :ok = Observer.revalidate_approved_head(17, "new-head", token: "test-gh-token", request_fun: base_request)

    queued_request = fn graphql_request ->
      {:ok, response} = base_request.(graphql_request)
      {:ok, put_in(response, [:body, "data", "repository", "pullRequest", "mergeQueueEntry"], %{"id" => "entry-17"})}
    end

    assert {:error, :approval_or_head_changed} = Observer.revalidate_approved_head(17, "new-head", token: "test-gh-token", request_fun: queued_request)
  end

  test "queue refresh batches only approved or already queued PRs" do
    parent = self()

    request = fn request ->
      query = request[:body]["query"]
      send(parent, {:query, query})

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "pr_0" => %{
                 "id" => "PR_17",
                 "state" => "OPEN",
                 "headRefOid" => "head-17",
                 "baseRefName" => "main",
                 "isDraft" => false,
                 "reviewDecision" => "APPROVED",
                 "mergeable" => "MERGEABLE",
                 "mergeStateStatus" => "CLEAN",
                 "mergeQueueEntry" => nil,
                 "autoMergeRequest" => nil,
                 "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "head-17"}}]},
                 "commits" => %{"nodes" => [%{"commit" => %{"committedDate" => "2026-10-14T00:00:00Z"}}]}
               }
             }
           }
         }
       }}
    end

    observations = [
      %{
        number: 17,
        raw: %{"reviewDecision" => "APPROVED", "headRefOid" => "head-17", "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "head-17"}}]}},
        rest: %{"number" => 17, "head" => %{"ref" => "aiur/17-work"}}
      },
      %{number: 18, raw: %{"reviewDecision" => "CHANGES_REQUESTED", "headRefOid" => "head-18"}, merge_queue_entry: nil}
    ]

    assert {:ok, [%{number: 17}]} = Observer.refresh_queue(observations, token: "test-gh-token", request_fun: request)
    assert_received {:query, query}
    assert query =~ "pullRequest(number: 17)"
    refute query =~ "pullRequest(number: 18)"
  end
end

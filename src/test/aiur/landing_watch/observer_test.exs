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
          # The daemon's update-branch budget is one call per base SHA (#6088).
          assert query =~ "baseRefOid"
          assert query =~ "parents(first: 2)"

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
                     "baseRefOid" => "main-17",
                     "isDraft" => false,
                     "reviewDecision" => "APPROVED",
                     "mergeable" => "MERGEABLE",
                     "mergeStateStatus" => "CLEAN",
                     "mergeQueueEntry" => %{"id" => "entry-17"},
                     "autoMergeRequest" => nil,
                     "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "head-17"}}]},
                     "commits" => %{
                       "nodes" => [
                         %{"commit" => %{"committedDate" => "2026-10-14T00:00:00Z", "parents" => %{"nodes" => [%{"oid" => "parent-a"}, %{"oid" => "main-17"}]}}}
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
    # A daemon merge head is recognised by its parents when its auto-merge arm is retried (#6088).
    assert pr.head_parents == ["parent-a", "main-17"]
    assert pr.number == 17
    assert pr.head == "head-17"
    assert pr.head_committed_at == "2026-10-14T00:00:00Z"
    assert pr.base_oid == "main-17"
    assert pr.merge_queue_entry == %{"id" => "entry-17"}
  end

  test "approval revalidation requires the exact current head" do
    base_request = fn graphql_request ->
      query = graphql_request[:body]["query"]
      assert query =~ "headRefOid"
      assert query =~ "mergeQueueEntry"
      assert query =~ "mergeable mergeStateStatus"

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => "new-head",
                 "reviewDecision" => "APPROVED",
                 "mergeable" => "MERGEABLE",
                 "mergeStateStatus" => "CLEAN",
                 "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "new-head"}}]}
               }
             }
           }
         }
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

  test "queue admission distinguishes a conflict from an unavailable exact-head verdict" do
    for mergeable <- [nil] do
      request = fn _graphql_request ->
        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "repository" => %{
                 "pullRequest" => %{
                   "headRefOid" => "new-head",
                   "reviewDecision" => "APPROVED",
                   "mergeable" => mergeable,
                   "mergeStateStatus" => "CLEAN",
                   "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "new-head"}}]}
                 }
               }
             }
           }
         }}
      end

      assert {:error, :mergeability_unavailable} =
               Observer.revalidate_approved_head(17, "new-head", token: "test-gh-token", request_fun: request)
    end

    conflict_request = fn _graphql_request ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => "new-head",
                 "reviewDecision" => "APPROVED",
                 "mergeable" => "CONFLICTING",
                 "mergeStateStatus" => "BEHIND",
                 "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "new-head"}}]}
               }
             }
           }
         }
       }}
    end

    assert {:error, :merge_conflict} =
             Observer.revalidate_approved_head(17, "new-head", token: "test-gh-token", request_fun: conflict_request)
  end

  test "current mergeability permits CLEAN and UNSTABLE while UNKNOWN is held" do
    for {mergeable, merge_state, expected} <- [
          {"MERGEABLE", "CLEAN", :ok},
          {"MERGEABLE", "UNSTABLE", :ok},
          {"UNKNOWN", "UNKNOWN", {:hold, :mergeability_unknown}}
        ] do
      request = fn _graphql_request ->
        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "repository" => %{
                 "pullRequest" => %{
                   "headRefOid" => "new-head",
                   "reviewDecision" => "APPROVED",
                   "mergeable" => mergeable,
                   "mergeStateStatus" => merge_state,
                   "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "new-head"}}]}
                 }
               }
             }
           }
         }}
      end

      assert ^expected = Observer.revalidate_approved_head(17, "new-head", token: "test-gh-token", request_fun: request)
    end

    required_status_pending = fn _graphql_request ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "headRefOid" => "new-head",
                 "reviewDecision" => "APPROVED",
                 "mergeable" => "MERGEABLE",
                 "mergeStateStatus" => "BLOCKED",
                 "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "new-head"}}]}
               }
             }
           }
         }
       }}
    end

    assert {:error, :mergeability_unavailable} =
             Observer.revalidate_approved_head(17, "new-head", token: "test-gh-token", request_fun: required_status_pending)
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

  test "queue position lookup returns only pull requests ahead of the observed entry" do
    request = fn graphql_request ->
      query = graphql_request[:body]["query"]
      assert query =~ "mergeQueue{entries(first:$limit)"
      assert graphql_request[:body]["variables"][:limit] == 3

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "mergeQueue" => %{
                   "entries" => %{
                     "nodes" => [
                       %{"position" => 1, "pullRequest" => %{"number" => 5009}},
                       %{"position" => 2, "pullRequest" => %{"number" => 5414}},
                       %{"position" => 3, "pullRequest" => %{"number" => 5007}},
                       %{"position" => 4, "pullRequest" => %{"number" => 4999}}
                     ]
                   }
                 }
               }
             }
           }
         }
       }}
    end

    observation = %{number: 4999, merge_queue_entry: %{"position" => 4}}
    assert {:ok, [5009, 5414, 5007]} = Observer.prs_ahead(observation, token: "test-gh-token", request_fun: request)
  end
end

defmodule Aiur.GitHub.OptimisticFailureTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.OptimisticFailure

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_token) end)
    :ok
  end

  test "confirms sparse closes as merged and replaces failed blockers with open PRs" do
    merged = %{"number" => 77, "state" => "closed", "merged" => true}

    request_fun = fn %{url: url, caller: "optimistic_guard_read"} ->
      {:ok, %{status: 200, body: if(String.ends_with?(url, "/pulls/77"), do: merged, else: [])}}
    end

    assert {:ok, ^merged} = OptimisticFailure.optimistic_blocker("42", 77, request_fun: request_fun)

    replacement = %{"number" => 78, "state" => "open", "head" => %{"ref" => "aiur/42-new"}}

    replacement_fun = fn %{url: url} ->
      {:ok, %{status: 200, body: if(String.ends_with?(url, "/pulls/77"), do: %{"state" => "closed", "merged" => false}, else: [replacement])}}
    end

    assert {:ok, pr} = OptimisticFailure.optimistic_blocker("42", 77, request_fun: replacement_fun)
    assert Map.take(pr, ["head", "number", "state"]) == replacement
    assert {:error, :optimistic_blocker_pr_unreadable} = OptimisticFailure.optimistic_blocker("42", 77, request_fun: fn _ -> {:ok, %{status: 200, body: %{}}} end)
  end

  test "an open-list match with missing or closed state is unreadable" do
    for state <- [nil, "closed"] do
      replacement = %{"number" => 78, "state" => state, "head" => %{"ref" => "aiur/42-new"}}

      request_fun = fn %{url: url} ->
        {:ok, %{status: 200, body: if(String.ends_with?(url, "/pulls/77"), do: %{"state" => "closed", "merged" => false}, else: [replacement])}}
      end

      assert {:error, :optimistic_blocker_pr_unreadable} = OptimisticFailure.optimistic_blocker("42", 77, request_fun: request_fun)
    end
  end

  test "conditional approval lookup keeps its GitHub caller through optimistic blocker reads" do
    request_fun = fn
      %{method: :get, caller: "optimistic_guard_read", url: url} ->
        {:ok,
         %{
           status: 200,
           body:
             if(String.ends_with?(url, "/pulls/77"),
               do: %{"number" => 77, "state" => "open", "merged" => false},
               else: [%{"number" => 77, "state" => "open", "head" => %{"ref" => "aiur/42", "sha" => "head"}}]
             )
         }}

      %{method: :post, url: "https://api.github.com/graphql", caller: "optimistic_guard_approval", body: %{"query" => query}} ->
        send(self(), {:approval_request, query})

        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "repository" => %{"pullRequest" => %{"headRefOid" => "head", "mergeable" => "MERGEABLE", "reviewDecision" => "APPROVED", "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "head"}}]}}}
             }
           }
         }}
    end

    assert {:ok, pr} = OptimisticFailure.optimistic_blocker("42", 77, approval_check?: true, approval_conflicts_count: 4, request_fun: request_fun)
    assert pr["approval"].approved?
    assert pr["approval"].checked_conflicts == 4
    assert_received {:approval_request, query}
    assert String.contains?(query, "AiurPullRequestApprovalAtHead")
  end

  test "draft conversion sends the PR node id and verifies the returned draft state" do
    test_pid = self()

    request_fun = fn
      %{method: :get, caller: "optimistic_guard_read"} ->
        {:ok, %{status: 200, body: [%{"draft" => false, "node_id" => "PR_node", "head" => %{"ref" => "aiur/42"}}]}}

      %{method: :post, caller: "optimistic_guard_draft", body: body} ->
        send(test_pid, {:draft_mutation, body})
        {:ok, %{status: 200, body: %{"data" => %{"convertPullRequestToDraft" => %{"pullRequest" => %{"isDraft" => true}}}}}}
    end

    assert :ok = OptimisticFailure.park_pull_request("42", request_fun: request_fun)
    assert_receive {:draft_mutation, %{"variables" => %{"id" => "PR_node"}, "query" => query}}, 1_000
    assert String.contains?(query, "convertPullRequestToDraft")

    failure_fun = fn
      %{method: :get} -> {:ok, %{status: 200, body: [%{"draft" => false, "node_id" => "PR_node", "head" => %{"ref" => "aiur/42"}}]}}
      %{method: :post} -> {:ok, %{status: 200, body: %{"errors" => [%{"message" => "Denied"}]}}}
    end

    assert {:error, :optimistic_park_draft_unverified} = OptimisticFailure.park_pull_request("42", request_fun: failure_fun)
  end

  test "a later-page park marker prevents a duplicate comment after restart" do
    next = "https://api.github.com/repos/owner/repo/issues/42/comments?page=2"
    test_pid = self()

    request_fun = fn %{method: :get, url: url, caller: "optimistic_guard_comment"} ->
      send(test_pid, {:comment_page, url})

      if url == next,
        do: {:ok, %{status: 200, body: [%{"body" => "parked\n<!-- optimistic-park:42:7 -->"}]}},
        else: {:ok, %{status: 200, body: [%{"body" => "unrelated"}], headers: [{"link", "<#{next}>; rel=\"next\""}]}}
    end

    assert :ok = OptimisticFailure.comment_optimistic_park("42", "7", :pr_closed_unmerged, request_fun: request_fun)
    assert_received {:comment_page, "https://api.github.com/repos/owner/repo/issues/42/comments?per_page=100"}
    assert_received {:comment_page, ^next}
  end

  test "posts once and reads back the exact comment body" do
    test_pid = self()
    {:ok, posted} = Agent.start_link(fn -> nil end)

    request_fun = fn
      %{method: :get, caller: "optimistic_guard_comment"} ->
        send(test_pid, {:comment_read, Agent.get(posted, & &1)})
        {:ok, %{status: 200, body: Agent.get(posted, fn body -> if body, do: [%{"body" => body}], else: [] end)}}

      %{method: :post, caller: "optimistic_guard_comment", body: %{"body" => body}} ->
        Agent.update(posted, fn _ -> body end)
        {:ok, %{status: 201}}
    end

    assert :ok = OptimisticFailure.comment_optimistic_park("42", "7", :pr_closed_unmerged, request_fun: request_fun)
    assert_received {:comment_read, nil}
    assert_received {:comment_read, verified_body}
    assert verified_body == Agent.get(posted, & &1)
    assert String.contains?(verified_body, "<!-- optimistic-park:42:7 -->")
    assert String.contains?(Agent.get(posted, & &1), "Wait for a replacement")
    Agent.stop(posted)
  end

  test "unverified writes and incomplete comment lists fail closed" do
    missing_body = fn
      %{method: :get} -> {:ok, %{status: 200, body: []}}
      %{method: :post} -> {:ok, %{status: 201}}
    end

    assert {:error, :optimistic_park_comment_unverified} = OptimisticFailure.comment_optimistic_park("42", "7", :pr_closed_unmerged, request_fun: missing_body)
    next = "https://api.github.com/repos/owner/repo/issues/42/comments?page=2"

    incomplete = fn %{method: :get, url: url} ->
      if url == next,
        do: {:error, :offline},
        else: {:ok, %{status: 200, body: [], headers: [{"link", "<#{next}>; rel=\"next\""}]}}
    end

    assert {:error, _reason} = OptimisticFailure.comment_optimistic_park("42", "7", :pr_closed_unmerged, request_fun: incomplete)
  end
end

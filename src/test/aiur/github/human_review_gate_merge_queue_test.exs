defmodule Aiur.GitHub.HumanReviewGateMergeQueueTest do
  # #4204: a head approved at its current commit and already in the merge queue
  # (or armed to enter it) is tested merged with the base before it lands, and a
  # queued branch rejects pushes, so the hand-off gate must refuse it only for a
  # real conflict. Every other head keeps the overlap check.
  use Aiur.TestSupport

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.GitHub.{Client, HumanReviewGate, ResourceStore}
  alias Aiur.Issue
  alias Aiur.Orchestrator.ReworkGate

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}
  @shared [%{"filename" => "shared.ex"}]
  @queued %{"id" => "MQE_1"}
  @approved_queued %{
    "headRefOid" => "tested-head",
    "baseRefName" => "main",
    "mergeable" => "MERGEABLE",
    "reviewDecision" => "APPROVED",
    "mergeQueueEntry" => @queued,
    "autoMergeRequest" => nil,
    "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "tested-head"}}]}
  }

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      case prev_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    ResourceStore.reset()
    on_exit(fn -> ResourceStore.reset() end)
    :ok
  end

  test "an approved, queued head behind an overlapping base hands off with no refusal for the agent to escalate" do
    executor = executor(request_fun(%{"mergeable" => "UNKNOWN"}, @shared))

    assert %{"success" => true} = executor.("aiur_set_ticket_state", %{"state" => "human-review"})
    assert_receive {:label_written, ["agent:human-review"]}, 1000
  end

  test "approved with auto-merge armed passes, and an unreadable file list does not block a landing head" do
    capped = List.duplicate(%{"filename" => "file.ex"}, 300)

    for {pull_request, upstream} <- [
          {%{"mergeQueueEntry" => nil, "autoMergeRequest" => %{"enabledAt" => "2026-10-10T22:00:00Z"}}, @shared},
          {%{}, capped}
        ] do
      assert :ok = Client.update_issue_state("42", "human-review", request_fun: request_fun(pull_request, upstream), bot_account: "aiur-bot")
      assert_receive {:label_written, ["agent:human-review"]}, 1000
    end
  end

  test "an overlapping head that is not approved at its current commit and landing keeps the overlap refusal" do
    older = %{"nodes" => [%{"commit" => %{"oid" => "older-head"}}]}

    cases = [
      {"review required, queued", %{"reviewDecision" => "REVIEW_REQUIRED"}},
      {"never reviewed, queued", %{"reviewDecision" => nil, "reviews" => %{"nodes" => []}}},
      {"changes requested, queued", %{"reviewDecision" => "CHANGES_REQUESTED"}},
      {"approved, neither queued nor armed", %{"mergeQueueEntry" => nil}},
      {"approved at an older commit, queued", %{"reviews" => older}},
      {"approved with no approving review, queued", %{"reviews" => %{"nodes" => []}}}
    ]

    for {label, pull_request} <- cases do
      result = Client.update_issue_state("42", "human-review", request_fun: request_fun(pull_request, @shared), bot_account: "aiur-bot")
      assert {:error, {:stale_review_base, %{pr_number: 77}}} = result, label
      refute_receive {:label_written, _labels}, 50
    end
  end

  test "a CONFLICTING queued pull request still refuses hand-off with an actionable reason" do
    executor = executor(request_fun(%{"mergeable" => "CONFLICTING"}, []))

    response = executor.("aiur_set_ticket_state", %{"state" => "human-review"})
    assert response["success"] == false
    error = Jason.decode!(response["output"])["error"]
    assert error["reason"] == "stale_review_base"
    assert error["detail"] == %{"pr_number" => 77, "base_branch" => "main", "head_sha" => "tested-head"}
    assert error["message"] =~ "conflicts with"
    assert error["message"] =~ "Never dequeue"
    refute_receive {:label_written, _labels}, 100
  end

  describe "the rework writer leaves a pull request approved at its head and queued alone" do
    @pr %{"number" => 77, "head" => %{"sha" => "tested-head"}}
    @threads [open_pr_fetcher: &__MODULE__.open_pr/1, unresolved_threads_fetcher: &__MODULE__.unresolved/1]

    test "an unresolved thread does not route it to rework" do
      assert ReworkGate.verify_unresolved_review_threads("42", rework_opts(queued_approval(%{}))) == {:skip, :approved_and_queued}
    end

    test "an unapproved, unqueued, stale-approval or unreadable pull request keeps the rework verdict" do
      responses = [
        queued_approval(%{"reviewDecision" => "CHANGES_REQUESTED"}),
        queued_approval(%{"mergeQueueEntry" => nil}),
        queued_approval(%{"reviews" => %{"nodes" => [%{"commit" => %{"oid" => "older-head"}}]}}),
        fn _req -> {:error, :timeout} end
      ]

      for response <- responses do
        assert ReworkGate.verify_unresolved_review_threads("42", rework_opts(response)) == {:ok, @pr}
      end
    end

    test "a blocking review submitted after the approval still routes to rework" do
      opts = rework_opts(queued_approval(%{})) ++ [blocking_review_submission?: true]
      assert ReworkGate.verify_unresolved_review_threads("42", opts) == {:ok, @pr}
    end
  end

  def open_pr(_issue_key), do: {:ok, @pr}
  def unresolved(_pr), do: {:ok, [%{"id" => "thread-1"}]}

  defp rework_opts(response) do
    @threads ++ [queued_approval_fetcher: fn pr -> HumanReviewGate.approved_and_queued?(pr["number"], request_fun: response) end]
  end

  defp queued_approval(pull_request) do
    fn %{method: :post, body: %{"query" => query, "variables" => %{"number" => 77}}} ->
      assert query =~ "AiurQueuedApproval"
      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequest" => Map.merge(@approved_queued, pull_request)}}}}}
    end
  end

  defp executor(request_fun) do
    ToolExecutor.build(%Issue{id: "42", identifier: "42"}, nil, nil, %{},
      coordination_runner: fn _key, operation, _opts -> operation.() end,
      ticket_state_writer: fn id, state -> Client.update_issue_state(id, state, request_fun: request_fun, bot_account: "aiur-bot") end
    )
  end

  # PR 77 is behind `main` and both sides changed `shared.ex` unless
  # `upstream_files` says otherwise — the shape the pre-#4204 gate refused.
  # `pull_request` overrides the approved-at-head, queued default.
  defp request_fun(pull_request, upstream_files) do
    parent = self()
    detail = Map.merge(@approved_queued, pull_request)
    threads = %{"reviewThreads" => %{"pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}, "nodes" => []}}

    # First match wins, on the URL or the GraphQL query name.
    routes = [
      {"/compare/main...tested-head", %{"status" => "diverged", "base_commit" => %{"sha" => "observed-base"}, "files" => @shared}},
      {"/compare/tested-head...observed-base", %{"status" => "diverged", "files" => upstream_files}},
      {"AiurHumanReviewMergeability", %{"data" => %{"repository" => %{"pullRequest" => detail}}}},
      {"AiurViewerLogin", %{"data" => %{"viewer" => %{"login" => "aiur-bot"}}}},
      {"AiurUnaddressedReviewThreads", %{"data" => %{"repository" => %{"pullRequest" => threads}}}},
      {"/pulls?", [%{"number" => 77, "head" => %{"ref" => "aiur/42", "sha" => "tested-head", "repo" => %{"full_name" => "owner/repo"}}}]},
      {"/issues/42/labels", []},
      {"/issues/42", %{"state" => "open", "labels" => [%{"name" => "agent:rework"}]}}
    ]

    fn req ->
      body = Map.get(req, :body) || %{}
      text = req.url <> " " <> to_string(body["query"])
      if req.method == :post and is_list(body["labels"]), do: send(parent, {:label_written, body["labels"]})
      {_route, response} = Enum.find(routes, fn {route, _response} -> text =~ route end)
      {:ok, %{status: 200, body: response}}
    end
  end
end

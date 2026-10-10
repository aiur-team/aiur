defmodule Aiur.GitHub.HumanReviewGateMergeQueueTest do
  # #4204: under a merge queue a head behind its base is normal — the queue
  # tests the merge before it lands — and a queued branch rejects pushes, so the
  # hand-off gate must refuse only a real conflict.
  use Aiur.TestSupport

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.GitHub.{Client, HumanReviewGate, ResourceStore}
  alias Aiur.Issue
  alias Aiur.Orchestrator.ReworkGate

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}
  @shared [%{"filename" => "shared.ex"}]

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
    request_fun = request_fun(%{"mergeQueue" => %{"id" => "MQ_1"}}, %{"mergeable" => "UNKNOWN", "mergeQueueEntry" => %{"id" => "MQE_1"}}, @shared)

    executor =
      ToolExecutor.build(%Issue{id: "42", identifier: "42"}, nil, nil, %{},
        coordination_runner: fn _key, operation, _opts -> operation.() end,
        ticket_state_writer: fn id, state -> Client.update_issue_state(id, state, request_fun: request_fun, bot_account: "aiur-bot") end
      )

    assert %{"success" => true} = executor.("aiur_set_ticket_state", %{"state" => "human-review"})
    assert_receive {:label_written, ["agent:human-review"]}, 1000
  end

  test "either queue signal alone lets a stale overlapping head through, and an unreadable file list no longer blocks it" do
    capped = List.duplicate(%{"filename" => "file.ex"}, 300)

    for {repository, pull_request, upstream} <- [
          {%{"mergeQueue" => %{"id" => "MQ_1"}}, %{"mergeable" => "MERGEABLE", "mergeQueueEntry" => nil}, @shared},
          {%{"mergeQueue" => nil}, %{"mergeable" => "MERGEABLE", "mergeQueueEntry" => %{"id" => "MQE_1"}}, @shared},
          {%{"mergeQueue" => %{"id" => "MQ_1"}}, %{"mergeable" => "MERGEABLE", "mergeQueueEntry" => %{"id" => "MQE_1"}}, capped}
        ] do
      assert :ok = Client.update_issue_state("42", "human-review", request_fun: request_fun(repository, pull_request, upstream), bot_account: "aiur-bot")
      assert_receive {:label_written, ["agent:human-review"]}, 1000
    end
  end

  test "without a merge queue the overlap refusal stands" do
    request_fun = request_fun(%{"mergeQueue" => nil}, %{"mergeable" => "MERGEABLE", "mergeQueueEntry" => nil}, @shared)

    assert {:error, {:stale_review_base, %{pr_number: 77}}} = Client.update_issue_state("42", "human-review", request_fun: request_fun, bot_account: "aiur-bot")
    refute_receive {:label_written, _labels}, 100
  end

  test "a CONFLICTING queued pull request still refuses hand-off with an actionable reason" do
    request_fun = request_fun(%{"mergeQueue" => %{"id" => "MQ_1"}}, %{"mergeable" => "CONFLICTING", "mergeQueueEntry" => %{"id" => "MQE_1"}}, [])

    executor =
      ToolExecutor.build(%Issue{id: "42", identifier: "42"}, nil, nil, %{},
        coordination_runner: fn _key, operation, _opts -> operation.() end,
        ticket_state_writer: fn id, state -> Client.update_issue_state(id, state, request_fun: request_fun, bot_account: "aiur-bot") end
      )

    response = executor.("aiur_set_ticket_state", %{"state" => "human-review"})
    assert response["success"] == false
    error = Jason.decode!(response["output"])["error"]
    assert error["reason"] == "stale_review_base"
    assert error["detail"] == %{"pr_number" => 77, "base_branch" => "main", "head_sha" => "tested-head"}
    assert error["message"] =~ "conflicts with"
    assert error["message"] =~ "Never dequeue"
    refute_receive {:label_written, _labels}, 100
  end

  describe "the rework writer leaves an approved, queued pull request alone" do
    @pr %{"number" => 77, "head" => %{"sha" => "tested-head"}}
    @threads [open_pr_fetcher: &__MODULE__.open_pr/1, unresolved_threads_fetcher: &__MODULE__.unresolved/1]

    test "an unresolved thread does not route it to rework" do
      opts = @threads ++ [queued_approval_fetcher: fn pr -> HumanReviewGate.approved_and_queued?(pr["number"], request_fun: queued_approval("APPROVED", %{"id" => "MQE_1"})) end]
      assert ReworkGate.verify_unresolved_review_threads("42", opts) == {:skip, :approved_and_queued}
    end

    test "an unapproved, unqueued or unreadable pull request keeps the rework verdict" do
      for response <- [queued_approval("CHANGES_REQUESTED", %{"id" => "MQE_1"}), queued_approval("APPROVED", nil), fn _req -> {:error, :timeout} end] do
        opts = @threads ++ [queued_approval_fetcher: fn pr -> HumanReviewGate.approved_and_queued?(pr["number"], request_fun: response) end]
        assert ReworkGate.verify_unresolved_review_threads("42", opts) == {:ok, @pr}
      end
    end
  end

  def open_pr(_issue_key), do: {:ok, @pr}
  def unresolved(_pr), do: {:ok, [%{"id" => "thread-1"}]}

  defp queued_approval(decision, entry) do
    fn %{method: :post, body: %{"query" => query, "variables" => %{"number" => 77}}} ->
      assert query =~ "AiurQueuedApproval"
      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequest" => %{"reviewDecision" => decision, "mergeQueueEntry" => entry}}}}}}
    end
  end

  # PR 77 is approved, behind `main`, and both sides changed `shared.ex` unless
  # `upstream_files` says otherwise — the shape the pre-#4204 gate refused.
  defp request_fun(repository, pull_request, upstream_files) do
    parent = self()
    detail = Map.merge(%{"headRefOid" => "tested-head", "baseRefName" => "main"}, pull_request)
    threads = %{"reviewThreads" => %{"pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}, "nodes" => []}}

    # First match wins, on the URL or the GraphQL query name.
    routes = [
      {"/compare/main...tested-head", %{"status" => "diverged", "base_commit" => %{"sha" => "observed-base"}, "files" => @shared}},
      {"/compare/tested-head...observed-base", %{"status" => "diverged", "files" => upstream_files}},
      {"AiurHumanReviewMergeability", %{"data" => %{"repository" => Map.put(repository, "pullRequest", detail)}}},
      {"AiurViewerLogin", %{"data" => %{"viewer" => %{"login" => "aiur-bot"}}}},
      {"AiurUnaddressedReviewThreads", %{"data" => %{"repository" => %{"pullRequest" => threads}}}},
      {"/pulls?", [%{"number" => 77, "head" => %{"ref" => "aiur/42", "sha" => "tested-head", "repo" => %{"full_name" => "owner/repo"}}}]},
      {"/issues/42/labels", []},
      {"/issues/42", %{"state" => "open", "labels" => [%{"name" => "agent:rework"}]}}
    ]

    fn req ->
      body = Map.get(req, :body) || %{}
      text = req.url <> " " <> to_string(body["query"])
      if text =~ "AiurHumanReviewMergeability", do: assert(body["variables"]["base"] == "main")
      if req.method == :post and is_list(body["labels"]), do: send(parent, {:label_written, body["labels"]})
      {_route, response} = Enum.find(routes, fn {route, _response} -> text =~ route end)
      {:ok, %{status: 200, body: response}}
    end
  end
end

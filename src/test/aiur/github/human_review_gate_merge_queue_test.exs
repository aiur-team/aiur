defmodule Aiur.GitHub.HumanReviewGateMergeQueueTest do
  # These scenarios exercise the state-write gate using pinned REST/GraphQL
  # responses, including commit ancestry and patch equivalence after base merges.
  # #4204: a head approved at its current commit and already in the merge queue
  # (or armed to enter it) is tested merged with the base before it lands, and a
  # queued branch rejects pushes, so the hand-off gate must refuse it only for a
  # real conflict. An approved current head also survives overlap-only staleness.
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
    assert_received {:label_written, ["agent:human-review"]}
  end

  test "an approved current head behind an overlapping base hands off without integration" do
    executor = executor(request_fun(%{"mergeQueueEntry" => nil, "autoMergeRequest" => nil}, @shared))

    assert %{"success" => true} = executor.("aiur_set_ticket_state", %{"state" => "human-review"})
    assert_received {:label_written, ["agent:human-review"]}
  end

  test "approved with auto-merge armed passes, and an unreadable file list does not block a landing head" do
    capped = List.duplicate(%{"filename" => "file.ex"}, 300)

    for {pull_request, upstream} <- [
          {%{"mergeQueueEntry" => nil, "autoMergeRequest" => %{"enabledAt" => "2026-10-10T22:00:00Z"}}, @shared},
          {%{}, capped}
        ] do
      assert :ok = Client.update_issue_state("42", "human-review", request_fun: request_fun(pull_request, upstream), bot_account: "aiur-bot")
      assert_received {:label_written, ["agent:human-review"]}
    end
  end

  test "an overlapping head that is not approved at its current commit and landing keeps the overlap refusal" do
    cases = [
      {"review required, queued", %{"reviewDecision" => "REVIEW_REQUIRED"}},
      {"never reviewed, queued", %{"reviewDecision" => nil, "reviews" => %{"nodes" => []}}},
      {"changes requested, queued", %{"reviewDecision" => "CHANGES_REQUESTED"}},
      {"approved with no approving review, queued", %{"reviews" => %{"nodes" => []}}}
    ]

    for {label, pull_request} <- cases do
      result = Client.update_issue_state("42", "human-review", request_fun: request_fun(pull_request, @shared), bot_account: "aiur-bot")
      assert {:error, {:stale_review_base, %{pr_number: 77}}} = result, label
      refute_received {:label_written, _labels}
    end
  end

  test "an approval summary without a current-head approving review keeps the overlap refusal" do
    detail = %{"mergeQueueEntry" => nil, "autoMergeRequest" => nil, "reviews" => %{"nodes" => []}}
    assert {:error, {:stale_review_base, %{pr_number: 77}}} = Client.update_issue_state("42", "human-review", request_fun: request_fun(detail, @shared), bot_account: "aiur-bot")
    refute_received {:label_written, _labels}
  end

  test "an approved overlapping head still refuses a genuine conflict" do
    assert {:error, {:stale_review_base, %{pr_number: 77}}} =
             Client.update_issue_state("42", "human-review",
               request_fun: request_fun(%{"mergeQueueEntry" => nil, "autoMergeRequest" => nil, "mergeable" => "CONFLICTING"}, @shared),
               bot_account: "aiur-bot"
             )

    refute_received {:label_written, _labels}
  end

  test "an approved head with only a merge from main after approval hands off" do
    assert :ok = Client.update_issue_state("42", "human-review", request_fun: merge_only_request_fun(:merge), bot_account: "aiur-bot")
    assert_received {:label_written, ["agent:human-review"]}
  end

  # These refusal cases guard the new merge-only exception from widening; the
  # old blanket stale-base gate also refuses them, so they are future-regression guards.
  test "a non-merge commit after the merge requires re-review even if the contribution is unchanged" do
    assert {:error, {:stale_review_base, %{head_sha: "tested-head"}}} =
             Client.update_issue_state("42", "human-review", request_fun: merge_only_request_fun(:non_merge), bot_account: "aiur-bot")

    refute_received {:label_written, _labels}
  end

  test "identical repeated context at a different hunk position still requires re-review" do
    assert {:error, {:stale_review_base, %{head_sha: "tested-head"}}} =
             Client.update_issue_state("42", "human-review", request_fun: merge_only_request_fun(:moved_repeated), bot_account: "aiur-bot")

    refute_received {:label_written, _labels}
  end

  test "multiple context replacements do not look like a nearby base edit" do
    assert {:error, {:stale_review_base, %{head_sha: "tested-head"}}} =
             Client.update_issue_state("42", "human-review", request_fun: merge_only_request_fun(:replaced_context), bot_account: "aiur-bot")

    refute_received {:label_written, _labels}
  end

  test "repeated context lines do not make a moved replacement look unchanged" do
    assert {:error, {:stale_review_base, %{head_sha: "tested-head"}}} =
             Client.update_issue_state("42", "human-review", request_fun: merge_only_request_fun(:repeated_context), bot_account: "aiur-bot")

    refute_received {:label_written, _labels}
  end

  test "a nearby base-only edit preserves the approved contribution" do
    assert :ok = Client.update_issue_state("42", "human-review", request_fun: merge_only_request_fun(:nearby_base), bot_account: "aiur-bot")
    assert_received {:label_written, ["agent:human-review"]}
  end

  test "base insertions before the feature hunk preserve the approved contribution" do
    assert :ok = Client.update_issue_state("42", "human-review", request_fun: merge_only_request_fun(:distant_base), bot_account: "aiur-bot")
    assert_received {:label_written, ["agent:human-review"]}
  end

  test "base insertion at the beginning of the file preserves the approved contribution" do
    assert :ok = Client.update_issue_state("42", "human-review", request_fun: merge_only_request_fun(:start_of_file_base), bot_account: "aiur-bot")
    assert_received {:label_written, ["agent:human-review"]}
  end

  test "single-line base changes with omitted hunk counts preserve the approved contribution" do
    assert :ok = Client.update_issue_state("42", "human-review", request_fun: merge_only_request_fun(:singleline_base), bot_account: "aiur-bot")
    assert_received {:label_written, ["agent:human-review"]}
  end

  test "an unrelated binary base file without a patch does not block handoff" do
    assert :ok = Client.update_issue_state("42", "human-review", request_fun: merge_only_request_fun(:unrelated_binary), bot_account: "aiur-bot")
    assert_received {:label_written, ["agent:human-review"]}
  end

  test "base deletion at the beginning of the file preserves the approved contribution" do
    assert :ok = Client.update_issue_state("42", "human-review", request_fun: merge_only_request_fun(:start_of_file_deletion), bot_account: "aiur-bot")
    assert_received {:label_written, ["agent:human-review"]}
  end

  test "an unrelated branch merge requires re-review" do
    assert {:error, {:stale_review_base, %{head_sha: "tested-head"}}} =
             Client.update_issue_state("42", "human-review", request_fun: merge_only_request_fun(:unrelated_merge), bot_account: "aiur-bot")

    refute_received {:label_written, _labels}
  end

  test "moving an unchanged replacement to another occurrence still requires re-review" do
    assert {:error, {:stale_review_base, %{head_sha: "tested-head"}}} =
             Client.update_issue_state("42", "human-review", request_fun: merge_only_request_fun(:moved_feature), bot_account: "aiur-bot")

    refute_received {:label_written, _labels}
  end

  test "a merge commit that changes the approved PR contribution still requires re-review" do
    assert {:error, {:stale_review_base, %{head_sha: "tested-head"}}} =
             Client.update_issue_state("42", "human-review", request_fun: merge_only_request_fun(:changed_merge), bot_account: "aiur-bot")

    refute_received {:label_written, _labels}
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
    refute_received {:label_written, _labels}
  end

  test "pull_request_mergeability returns only GitHub's explicit mergeability status" do
    for status <- ["MERGEABLE", "CONFLICTING", "UNKNOWN"] do
      fetch = fn %{method: :post, body: %{"query" => query, "variables" => %{"number" => 77}}} ->
        assert query =~ "AiurPullRequestMergeability"
        {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequest" => %{"mergeable" => status}}}}}}
      end

      assert HumanReviewGate.pull_request_mergeability(77, request_fun: fetch) == {:ok, status}
    end
  end

  test "pull_request_approved_at_head? requires approval on the current head" do
    for {head, review, expected} <- [
          {"tested-head", %{"oid" => "tested-head"}, true},
          {"tested-head", %{"oid" => "older-head"}, false}
        ] do
      fetch = fn %{method: :post, body: %{"query" => query, "variables" => %{"number" => 77}}} ->
        assert query =~ "AiurPullRequestApprovalAtHead"
        body = %{"headRefOid" => head, "reviewDecision" => "APPROVED", "reviews" => %{"nodes" => [%{"commit" => review}]}}
        {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequest" => body}}}}}
      end

      assert Client.pull_request_approved_at_head?(77, request_fun: fetch) == {:ok, expected}
    end
  end

  test "pull_request_approved_at_head? rejects malformed review observations" do
    fetch = fn _req ->
      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequest" => %{"headRefOid" => "tested-head"}}}}}}
    end

    assert Client.pull_request_approved_at_head?(77, request_fun: fetch) == {:error, :invalid_pull_request_approval}
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

  defp merge_only_request_fun(scenario) do
    fallback = request_fun(approved_pull_request(), scenario_files(scenario))
    comparison_request_fun(fallback, scenario)
  end

  defp approved_pull_request do
    %{
      "headRefOid" => "tested-head",
      "reviewDecision" => "APPROVED",
      "mergeQueueEntry" => nil,
      "autoMergeRequest" => nil,
      "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "approved-head"}}]}
    }
  end

  defp scenario_files(_scenario), do: @shared

  defp comparison_request_fun(fallback, scenario) do
    approved_patch = scenario_approved_patch(scenario)
    current_patch = scenario_patch(scenario, approved_patch)
    post_commits = scenario_post_commits(scenario)

    fn req ->
      comparison_response(req, scenario, approved_patch, current_patch, post_commits, fallback)
    end
  end

  defp scenario_approved_patch(:repeated_context), do: "@@ -1,8 +1,8 @@\n \n \n \n \n-old feature\n+new feature\n \n \n \n \n"
  defp scenario_approved_patch(:moved_repeated), do: "@@ -10,6 +10,6 @@\n same\n same\n-old feature\n+new feature\n same\n same"
  defp scenario_approved_patch(:replaced_context), do: "@@ -1,5 +1,5 @@\n before\n first\n second\n-old feature\n+new feature\n after"
  defp scenario_approved_patch(:singleline_base), do: "@@ -5,3 +5,3 @@\n before\n-old feature\n+new feature\n after"
  defp scenario_approved_patch(:start_of_file_deletion), do: "@@ -5,3 +5,3 @@\n before\n-old feature\n+new feature\n after"
  defp scenario_approved_patch(_scenario), do: "@@ -1,3 +1,3 @@\n before\n-old feature\n+new feature\n after"

  defp scenario_patch(:changed_merge, _patch), do: "@@ -1 +1 @@\n-old feature\n+resolved feature"
  defp scenario_patch(:moved_feature, _patch), do: "@@ -1,3 +1,3 @@\n other occurrence\n-old feature\n+new feature"
  defp scenario_patch(:nearby_base, _patch), do: "@@ -1,4 +1,4 @@\n before\n base-only nearby line\n-old feature\n+new feature\n after"
  defp scenario_patch(:distant_base, _patch), do: "@@ -5,3 +5,3 @@\n before\n-old feature\n+new feature\n after"
  defp scenario_patch(:start_of_file_base, _patch), do: "@@ -5,3 +5,3 @@\n before\n-old feature\n+new feature\n after"
  defp scenario_patch(:singleline_base, _patch), do: "@@ -5,3 +5,3 @@\n before\n-old feature\n+new feature\n after"
  defp scenario_patch(:start_of_file_deletion, _patch), do: "@@ -1,3 +1,3 @@\n before\n-old feature\n+new feature\n after"
  defp scenario_patch(:repeated_context, _patch), do: "@@ -1,4 +1,4 @@\n \n-old feature\n+new feature\n \n"
  defp scenario_patch(:moved_repeated, _patch), do: "@@ -40,6 +40,6 @@\n same\n same\n-old feature\n+new feature\n same\n same"
  defp scenario_patch(:replaced_context, _patch), do: "@@ -1,5 +1,5 @@\n before\n changed first\n changed second\n-old feature\n+new feature\n after"
  defp scenario_patch(_scenario, patch), do: patch

  defp scenario_post_commits(:non_merge) do
    [{"main-commit", nil}, {"feature-commit", [%{"sha" => "approved-head"}]}]
  end

  defp scenario_post_commits(:unrelated_merge) do
    [{"main-commit", nil}, {"merge-sha", [%{"sha" => "approved-head"}, %{"sha" => "side-parent"}]}]
  end

  defp scenario_post_commits(_scenario) do
    [{"main-commit", nil}, {"merge-sha", [%{"sha" => "approved-head"}, %{"sha" => "observed-base"}]}]
  end

  defp comparison_response(req, scenario, approved_patch, current_patch, post_commits, fallback) do
    url = req.url

    cond do
      url =~ "/compare/observed-base...observed-base?per_page=1" ->
        {:ok, %{status: 200, body: %{"status" => "identical"}}}

      url =~ "/compare/side-parent...observed-base?per_page=1" ->
        {:ok, %{status: 200, body: %{"status" => "diverged"}}}

      url =~ "/compare/observed-base...approved-head?per_page=100" ->
        {:ok, %{status: 200, body: %{"status" => "diverged", "merge_base_commit" => %{"sha" => "old-base"}}}}

      url =~ "/compare/old-base...observed-base?per_page=100" ->
        base_history_comparison(scenario)

      url =~ "/compare/approved-head...tested-head?per_page=100" ->
        post_approval_comparison(post_commits)

      url =~ "/compare/old-base...approved-head?per_page=100" ->
        {:ok, %{status: 200, body: %{"status" => "ahead", "files" => [%{"filename" => "feature.ex", "patch" => approved_patch}]}}}

      url =~ "/compare/main...tested-head?per_page=100" ->
        current_comparison(current_patch)

      true ->
        fallback.(req)
    end
  end

  defp base_history_comparison(scenario)
       when scenario in [:distant_base, :start_of_file_base, :singleline_base, :start_of_file_deletion] do
    patch = base_history_patch(scenario)

    {:ok,
     %{
       status: 200,
       body: %{
         "status" => "ahead",
         "total_commits" => 1,
         "commits" => [%{"sha" => "main-commit"}],
         "files" => [%{"filename" => "feature.ex", "patch" => patch}]
       }
     }}
  end

  defp base_history_comparison(:unrelated_binary) do
    {:ok,
     %{
       status: 200,
       body: %{
         "status" => "ahead",
         "total_commits" => 1,
         "commits" => [%{"sha" => "main-commit"}],
         "files" => [%{"filename" => "assets/logo.png"}]
       }
     }}
  end

  defp base_history_comparison(_scenario) do
    {:ok, %{status: 200, body: %{"status" => "ahead", "total_commits" => 1, "commits" => [%{"sha" => "main-commit"}], "files" => []}}}
  end

  defp base_history_patch(:start_of_file_base), do: "@@ -0,0 +1,4 @@\n+line one\n+line two\n+line three\n+line four"
  defp base_history_patch(:singleline_base), do: "@@ -1 +1 @@\n-old base line\n+new base line"
  defp base_history_patch(:start_of_file_deletion), do: "@@ -1,4 +0,0 @@\n-line one\n-line two\n-line three\n-line four"
  defp base_history_patch(:distant_base), do: "@@ -1,0 +1,4 @@\n+line one\n+line two\n+line three\n+line four"

  defp post_approval_comparison(post_commits) do
    commits = Enum.map(post_commits, fn {sha, parents} -> %{"sha" => sha, "parents" => parents || [%{"sha" => "old-base"}]} end)
    {:ok, %{status: 200, body: %{"status" => "ahead", "total_commits" => length(commits), "commits" => commits}}}
  end

  defp current_comparison(patch) do
    {:ok,
     %{
       status: 200,
       body: %{
         "status" => "ahead",
         "base_commit" => %{"sha" => "observed-base"},
         "merge_base_commit" => %{"sha" => "main"},
         "files" => [%{"filename" => "feature.ex", "patch" => patch}]
       }
     }}
  end
end

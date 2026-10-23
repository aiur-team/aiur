defmodule Aiur.Orchestrator.ReviewLandingWithdrawalTest do
  # #4676: a CHANGES_REQUESTED review must take a queued, auto-merging PR out of
  # the merge queue and turn auto-merge off; other reviews leave the queue alone.
  use Aiur.TestSupport

  alias Aiur.GitHub.LandingWithdrawal
  alias Aiur.Orchestrator.{ReviewLandingWithdrawal, State}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "a trusted CHANGES_REQUESTED review on a queued, auto-merging PR dequeues it and disables auto-merge" do
    ReviewLandingWithdrawal.changes_requested(%State{}, "42", review_event("CHANGES_REQUESTED"), opts())

    assert_received {:graphql, "AiurDequeuePullRequest", %{"id" => "PR_77"}}
    assert_received {:graphql, "AiurDisableAutoMerge", %{"id" => "PR_77"}}
    assert_received {:comment, "42", body}
    assert body =~ "removed it from the merge queue and turned auto-merge off"
  end

  test "regression guard: trusted CHANGES_REQUESTED disables auto-merge when the PR is not queued" do
    ReviewLandingWithdrawal.changes_requested(
      %State{},
      "42",
      review_event("CHANGES_REQUESTED"),
      opts(%{"mergeQueueEntry" => nil})
    )

    assert_received {:graphql, "AiurLandingWithdrawal", _variables}
    refute_received {:graphql, "AiurDequeuePullRequest", _variables}
    assert_received {:graphql, "AiurDisableAutoMerge", _variables}
  end

  test "a COMMENTED review does not touch the queue" do
    ReviewLandingWithdrawal.changes_requested(%State{}, "42", review_event("COMMENTED"), opts())

    refute_received {:graphql, _operation, _variables}
    refute_received {:comment, _identifier, _body}
  end

  test "an untrusted CHANGES_REQUESTED review does not touch the queue" do
    event = Map.put(review_event("CHANGES_REQUESTED"), :author_trusted?, false)
    ReviewLandingWithdrawal.changes_requested(%State{}, "42", event, opts())

    refute_received {:graphql, _operation, _variables}
  end

  test "a CHANGES_REQUESTED review on a since-approved or newer head does not touch the queue" do
    for context <- [%{"review_decision" => "APPROVED"}, %{"head_committed_at" => "2026-10-16T12:00:00Z"}] do
      event = review_event("CHANGES_REQUESTED") |> put_in([:comment, "submitted_at"], "2026-10-16T11:00:00Z") |> Map.put(:pull_request, context)
      ReviewLandingWithdrawal.changes_requested(%State{}, "42", event, opts())
    end

    refute_received {:graphql, _operation, _variables}
  end

  test "a PR neither queued nor auto-merging is read but not mutated or recorded" do
    ReviewLandingWithdrawal.changes_requested(%State{}, "42", review_event("CHANGES_REQUESTED"), opts(%{"mergeQueueEntry" => nil, "autoMergeRequest" => nil}))

    assert_received {:graphql, "AiurLandingWithdrawal", _variables}
    refute_received {:graphql, "AiurDequeuePullRequest", _variables}
    refute_received {:graphql, "AiurDisableAutoMerge", _variables}
    refute_received {:comment, _identifier, _body}
  end

  test "a CHANGES_REQUESTED review on another instance's ticket does not touch the queue (#5803)" do
    path = Workflow.workflow_file_path()
    write_workflow_file_atomic!(path, File.read!(path) <> "\ninstance:\n  ignore:\n    tickets: [42]\n")
    :ok = Aiur.WorkflowStore.force_reload()

    ReviewLandingWithdrawal.changes_requested(%State{}, "42", review_event("CHANGES_REQUESTED"), opts())

    refute_received {:graphql, _operation, _variables}
    refute_received {:comment, _identifier, _body}
  end

  defp review_event(state), do: %{author_trusted?: true, comment: %{"state" => state, "user" => %{"login" => "reviewer"}}}

  defp opts(pr_overrides \\ %{}) do
    parent = self()
    pr = Map.merge(%{"id" => "PR_77", "mergeQueueEntry" => %{"id" => "MQE_1"}, "autoMergeRequest" => %{"enabledAt" => "2026-10-16T00:00:00Z"}}, pr_overrides)

    request_fun = fn req ->
      %{"query" => query, "variables" => variables} = req.body
      [operation] = Regex.run(~r/(?:query|mutation) (\w+)/, query, capture: :all_but_first)
      send(parent, {:graphql, operation, variables})

      data =
        case operation do
          "AiurLandingWithdrawal" -> %{"repository" => %{"pullRequest" => pr}}
          "AiurDequeuePullRequest" -> %{"dequeuePullRequest" => %{"mergeQueueEntry" => %{"id" => "MQE_1"}}}
          "AiurDisableAutoMerge" -> %{"disablePullRequestAutoMerge" => %{"pullRequest" => %{"id" => "PR_77"}}}
        end

      {:ok, %{status: 200, body: %{"data" => data}}}
    end

    [
      open_pr_fetcher: fn "42" -> {:ok, %{"number" => 77}} end,
      withdraw: &LandingWithdrawal.withdraw(&1, token: "test-token", request_fun: request_fun),
      create_comment: fn identifier, body -> send(parent, {:comment, identifier, body}) end
    ]
  end
end

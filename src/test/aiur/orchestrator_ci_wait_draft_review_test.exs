defmodule Aiur.OrchestratorCiWaitDraftReviewTest do
  use Aiur.TestSupport

  alias Aiur.{Issue, Orchestrator.CiLifecycle, Orchestrator.State}

  defmodule RecordingTracker do
    def config_module, do: Aiur.Linear.Config

    def update_issue_state(issue_id, state, _opts) do
      send(Application.fetch_env!(:aiur, :ci_draft_review_recipient), {:state_write, issue_id, state})
      :ok
    end
  end

  setup do
    previous = Application.fetch_env!(:aiur, :tracker_adapters)
    Application.put_env(:aiur, :tracker_adapters, Map.put(previous, "github", RecordingTracker))
    Application.put_env(:aiur, :ci_draft_review_recipient, self())

    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent",
      tracker_active_states: ["todo", "in-progress"],
      tracker_terminal_states: ["done"]
    )

    on_exit(fn ->
      Application.put_env(:aiur, :tracker_adapters, previous)
      Application.delete_env(:aiur, :ci_draft_review_recipient)
    end)

    :ok
  end

  test "a pending draft already in human review is not moved to ci-wait" do
    identifier = "draft-review-#{System.unique_integer([:positive])}"
    issue = %Issue{id: identifier, identifier: identifier, state: "human-review"}

    state =
      CiLifecycle.poll_github_ci(%State{},
        ci_failure_digest: fn _, _ -> {:ok, %Aiur.CI.FailureDigest{}} end,
        parked_ready_alert_loader: fn -> MapSet.new() end,
        draft_stall_alert_loader: fn -> MapSet.new() end,
        ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
        ci_poller: fn [^identifier], _opts ->
          {:ok, %{results: [%{target: identifier, decision: :pending, pending_reason: :draft_pull_request, draft?: true}], errors: []}}
        end
      )

    assert %State{} = state
    refute_received {:state_write, ^identifier, "ci-wait"}
  end

  # open-games #293: a private repo on GitHub Free cannot read branch protection,
  # so every verdict is pending `:required_checks_unavailable` before the draft
  # check runs. Moving the draft to ci-wait let the fallback re-wake hand it to
  # the worker every few minutes while it waited on the creator's verdict.
  test "a draft in human review stays there when its required checks cannot be read" do
    identifier = "draft-review-#{System.unique_integer([:positive])}"
    issue = %Issue{id: identifier, identifier: identifier, state: "human-review"}

    state =
      CiLifecycle.poll_github_ci(%State{},
        ci_failure_digest: fn _, _ -> {:ok, %Aiur.CI.FailureDigest{}} end,
        parked_ready_alert_loader: fn -> MapSet.new() end,
        draft_stall_alert_loader: fn -> MapSet.new() end,
        ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
        ci_poller: fn [^identifier], _opts ->
          {:ok, %{results: [%{target: identifier, decision: :pending, pending_reason: :required_checks_unavailable, draft?: true}], errors: []}}
        end
      )

    assert %State{} = state
    refute_received {:state_write, ^identifier, "ci-wait"}
  end

  test "a ready pull request in human review with unreadable required checks still moves to ci-wait" do
    identifier = "draft-review-#{System.unique_integer([:positive])}"
    issue = %Issue{id: identifier, identifier: identifier, state: "human-review"}

    CiLifecycle.poll_github_ci(%State{},
      ci_failure_digest: fn _, _ -> {:ok, %Aiur.CI.FailureDigest{}} end,
      parked_ready_alert_loader: fn -> MapSet.new() end,
      draft_stall_alert_loader: fn -> MapSet.new() end,
      ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
      ci_poller: fn [^identifier], _opts ->
        {:ok, %{results: [%{target: identifier, decision: :pending, pending_reason: :required_checks_unavailable, draft?: false}], errors: []}}
      end
    )

    assert_receive {:state_write, ^identifier, "ci-wait"}, 1_000
  end
end

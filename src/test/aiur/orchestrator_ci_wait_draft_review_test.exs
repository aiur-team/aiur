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
end

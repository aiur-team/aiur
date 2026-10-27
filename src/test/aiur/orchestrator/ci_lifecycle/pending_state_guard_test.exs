defmodule Aiur.Orchestrator.CiLifecycle.PendingStateGuardTest do
  # #6108: pending or stale CI evidence must not overwrite an Executor's rework label
  # (or a working agent's in-progress) with ci-wait.
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.OrchestratorDeactivateSupport.CIWatcherGitHubClient

  import Aiur.OrchestratorDeactivateSupport

  setup do
    previous = for key <- [:github_client_module, :ci_watcher_recipient], into: %{}, do: {key, Application.get_env(:aiur, key)}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent",
      tracker_active_states: ["todo", "in-progress", "rework", "merging"],
      tracker_terminal_states: ["done", "cancelled", "canceled"]
    )

    Application.put_env(:aiur, :github_client_module, CIWatcherGitHubClient)
    Application.put_env(:aiur, :ci_watcher_recipient, self())
    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_application_env(key, value) end) end)
    :ok
  end

  for {ticket_state, pending_reason} <- [{"rework", :stale_ci_evidence}, {"rework", nil}, {"in-progress", :stale_ci_evidence}] do
    test "a #{ticket_state} ticket stays #{ticket_state} on a pending CI poll (#{inspect(pending_reason)})" do
      identifier = "6020"
      issue = %Issue{id: identifier, identifier: identifier, state: unquote(ticket_state), title: "Executor rework"}
      result = %{target: identifier, decision: :pending, pending_reason: unquote(pending_reason), head_sha: "pending-head", pr_number: 6020}

      CiLifecycle.poll_github_ci(empty_orchestrator_state(),
        ci_issue_fetcher: fn _states -> {:ok, [issue]} end,
        ci_poller: fn [^identifier], _opts -> {:ok, %{results: [result], errors: []}} end
      )

      refute_received {:ci_watcher_update, ^identifier, _state}
    end
  end

  test "a human-review ticket still returns to ci-wait on a pending CI poll" do
    issue = %Issue{id: "6021", identifier: "6021", state: "human-review", title: "Awaiting CI"}

    CiLifecycle.poll_github_ci(empty_orchestrator_state(),
      ci_issue_fetcher: fn _states -> {:ok, [issue]} end,
      ci_poller: fn ["6021"], _opts -> {:ok, %{results: [%{target: "6021", decision: :pending, head_sha: "h", pr_number: 6021}], errors: []}} end
    )

    receive_barrier({:ci_watcher_update, "6021", "ci-wait"})
  end
end

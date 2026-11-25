defmodule Aiur.Orchestrator.CiLifecycle.ExternalCiTest do
  # #8098: with `merge_policy.ci: external`, permanently red or absent GitHub
  # checks must not flip human-review <-> ci-wait or wake the agent.
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.OrchestratorDeactivateSupport.CIWatcherGitHubClient

  import Aiur.OrchestratorDeactivateSupport

  setup do
    previous = for key <- [:github_client_module, :ci_watcher_recipient], into: %{}, do: {key, Application.get_env(:aiur, key)}
    Application.put_env(:aiur, :github_client_module, CIWatcherGitHubClient)
    Application.put_env(:aiur, :ci_watcher_recipient, self())
    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_application_env(key, value) end) end)
    :ok
  end

  test "a human-review ticket with red checks stays asleep for an hour of polls" do
    configure_ci("external")
    issue = %Issue{id: "8098", identifier: "8098", state: "human-review", title: "External CI"}

    final =
      Enum.reduce(1..12, empty_orchestrator_state(), fn poll, state ->
        result =
          if rem(poll, 2) == 1,
            do: %{target: "8098", decision: :pending, head_sha: "h", pr_number: 8098, draft?: false},
            else: %{target: "8098", decision: :failed, failures: [%{name: "required"}], head_sha: "h", pr_number: 8098, draft?: false}

        CiLifecycle.poll_github_ci(%{state | last_ci_poll_started_at_ms: nil},
          ci_issue_fetcher: fn _states -> {:ok, [issue]} end,
          ci_poller: fn ["8098"], _opts -> {:ok, %{results: [result], errors: []}} end
        )
      end)

    refute_received {:ci_watcher_update, "8098", _state}
    assert Map.get(final.ci_lifecycle, :rewakes, %{}) == %{}
  end

  test "the same pending poll still flips human-review to ci-wait under wait" do
    configure_ci("wait")
    issue = %Issue{id: "8099", identifier: "8099", state: "human-review", title: "Wait CI"}

    CiLifecycle.poll_github_ci(empty_orchestrator_state(),
      ci_issue_fetcher: fn _states -> {:ok, [issue]} end,
      ci_poller: fn ["8099"], _opts -> {:ok, %{results: [%{target: "8099", decision: :pending, head_sha: "h", pr_number: 8099}], errors: []}} end
    )

    receive_barrier({:ci_watcher_update, "8099", "ci-wait"})
  end

  test "a ready PR left in ci-wait moves to human-review once" do
    configure_ci("external")
    issue = %Issue{id: "8100", identifier: "8100", state: "ci-wait", title: "Stranded wait"}

    CiLifecycle.poll_github_ci(empty_orchestrator_state(),
      ci_issue_fetcher: fn _states -> {:ok, [issue]} end,
      ci_poller: fn ["8100"], _opts -> {:ok, %{results: [%{target: "8100", decision: :failed, head_sha: "h", pr_number: 8100, draft?: false}], errors: []}} end
    )

    receive_barrier({:ci_watcher_update, "8100", "human-review"})
  end

  test "no CI-wait fallback wake is armed" do
    configure_ci("external")
    issue = %Issue{id: "8101", identifier: "8101", state: "ci-wait"}

    assert Map.get(CiLifecycle.arm_ci_wait_rewake(empty_orchestrator_state(), issue).ci_lifecycle, :rewakes, %{}) == %{}
  end

  defp configure_ci(mode) do
    path = Workflow.workflow_file_path()

    write_workflow_file!(path,
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent",
      tracker_active_states: ["todo", "in-progress", "rework", "merging"],
      tracker_terminal_states: ["done", "cancelled", "canceled"]
    )

    File.write!(path, File.read!(path) <> "\nmerge_policy:\n  ci: #{mode}\n")
    assert :ok = Aiur.WorkflowStore.force_reload()
  end
end

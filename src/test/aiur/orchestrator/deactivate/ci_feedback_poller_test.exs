defmodule Aiur.Orchestrator.Deactivate.CiFeedbackPollerTest do
  use Aiur.TestSupport

  alias Aiur.CIApprovalStore
  alias Aiur.Issue
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.OrchestratorDeactivateSupport.CIWatcherGitHubClient

  import Aiur.OrchestratorDeactivateSupport

  describe "GitHub CI feedback poller" do
    setup do
      previous_client = Application.get_env(:aiur, :github_client_module)
      previous_recipient = Application.get_env(:aiur, :ci_watcher_recipient)
      previous_issues = Application.get_env(:aiur, :ci_watcher_issues)
      previous_update_result = Application.get_env(:aiur, :ci_watcher_update_result)
      previous_ci_approval_store_path = Application.get_env(:aiur, :ci_approval_store_path)
      ci_approval_store_path = Aiur.TestSupport.tmp_root!("aiur_ci_approvals") <> ".json"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      Application.put_env(:aiur, :github_client_module, CIWatcherGitHubClient)
      Application.put_env(:aiur, :ci_watcher_recipient, self())
      Application.put_env(:aiur, :ci_approval_store_path, ci_approval_store_path)

      on_exit(fn ->
        restore_application_env(:github_client_module, previous_client)
        restore_application_env(:ci_watcher_recipient, previous_recipient)
        restore_application_env(:ci_watcher_issues, previous_issues)
        restore_application_env(:ci_watcher_update_result, previous_update_result)
        restore_application_env(:ci_approval_store_path, previous_ci_approval_store_path)
        File.rm(ci_approval_store_path)
      end)

      :ok
    end

    test "initial pending CI moves a human-review ticket into ci-wait" do
      issue = %Issue{id: "821", identifier: "821", state: "human-review", title: "Awaiting CI"}

      state =
        CiLifecycle.poll_github_ci(empty_orchestrator_state(),
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
          ci_poller: fn ["821"], _opts ->
            {:ok,
             %{
               results: [%{target: "821", decision: :pending, head_sha: "initial-head"}],
               errors: []
             }}
          end
        )

      receive_barrier({:ci_watcher_update, "821", "ci-wait"})
      assert state.running == %{}
    end

    test "pending CI cannot hand off an active turn with undelivered rework" do
      identifier = "ci-undelivered-rework"

      # This is the target snapshot captured before the CI poll. While that
      # poll was in flight, a trusted review opened a newer rework epoch on
      # the active runner and queued its concrete delivery item.
      stale_ci_target = %Issue{
        id: identifier,
        identifier: identifier,
        state: "human-review",
        title: "Stale CI target"
      }

      running_issue = %{stale_ci_target | state: "rework"}

      state = %{
        empty_orchestrator_state()
        | running: %{
            identifier => %{
              identifier: identifier,
              issue: running_issue,
              control: %{status: :working},
              lifecycle_fence: %{
                generation: 1,
                authoritative_state: "rework",
                pending_item_ids: MapSet.new([77]),
                opened_at: DateTime.utc_now()
              }
            }
          }
      }

      next =
        CiLifecycle.poll_github_ci(state,
          ci_issue_fetcher: fn ["ci-wait", "human-review"] ->
            {:ok, [stale_ci_target]}
          end,
          ci_poller: fn [^identifier], _opts ->
            {:ok,
             %{
               results: [
                 %{target: identifier, decision: :pending, head_sha: "stale-head"}
               ],
               errors: []
             }}
          end
        )

      # poll_github_ci/2 is synchronous, so its return is the barrier for every
      # tracker update this result could have attempted.
      refute_received {:ci_watcher_update, ^identifier, "ci-wait"}
      assert next.running[identifier].issue.state == "rework"
      assert next.running[identifier].control.status == :working

      assert next.running[identifier].lifecycle_fence.pending_item_ids ==
               MapSet.new([77])
    end

    test "pending CI preserves an approved human-review head" do
      identifier = "825"
      issue = %Issue{id: identifier, identifier: identifier, state: "human-review", title: "Awaiting CI"}
      agent_pid = control_test_agent(self())

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
      end)

      state =
        human_review_running_state(identifier, agent_pid)
        |> put_in([Access.key(:ci_lifecycle), :approved_heads], %{identifier => "approved-head"})
        |> CiLifecycle.poll_github_ci(
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
          ci_poller: fn [^identifier], _opts ->
            {:ok, %{results: [%{target: identifier, decision: :pending, head_sha: "approved-head"}], errors: []}}
          end
        )

      # poll_github_ci/2 is the barrier for both the control and tracker paths.
      control_agent_barrier(agent_pid)
      refute_received {:ci_wait_control, {:pause_agent, _request_id}}
      refute_received {:ci_watcher_update, ^identifier, "ci-wait"}

      entry = Map.fetch!(state.running, identifier)
      assert get_in(entry, [:control, :status]) == :working
      refute Map.has_key?(entry, :paused_reason)
      assert entry.issue.state == "human-review"
      assert Process.alive?(agent_pid)
    end

    test "a pending re-push returns a previously approved human-review ticket to ci-wait" do
      identifier = "ci-repush"
      issue = %Issue{id: identifier, identifier: identifier, state: "human-review", title: "Re-push CI"}

      state =
        empty_orchestrator_state()
        |> put_in([Access.key(:ci_lifecycle), :approved_heads], %{identifier => "approved-head"})
        |> CiLifecycle.poll_github_ci(
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
          ci_poller: fn [^identifier], _opts ->
            {:ok, %{results: [%{target: identifier, decision: :pending, head_sha: "replacement-head"}], errors: []}}
          end
        )

      receive_barrier({:ci_watcher_update, ^identifier, "ci-wait"})
      assert state.ci_lifecycle.approved_heads == %{}
    end

    test "passing CI promotes ci-wait only after the successful observation" do
      issue = %Issue{id: "822", identifier: "822", state: "ci-wait", title: "CI gate"}

      state =
        CiLifecycle.poll_github_ci(empty_orchestrator_state(),
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
          ci_poller: fn ["822"], _opts ->
            {:ok, %{results: [%{target: "822", decision: :passed, head_sha: "new-head", pr_number: 822}], errors: []}}
          end
        )

      receive_barrier({:ci_watcher_update, "822", "in-progress"})
      assert state.ci_lifecycle.approved_heads == %{"822" => "new-head"}
    end

    test "CI result cannot overwrite a newer rework state" do
      identifier = "ci-result-race"
      issue = %Issue{id: identifier, identifier: identifier, state: "ci-wait", title: "CI race"}

      Application.put_env(
        :aiur,
        :ci_watcher_update_result,
        {:error, {:stale_issue_state, "ci-wait", "rework"}}
      )

      state =
        CiLifecycle.poll_github_ci(empty_orchestrator_state(),
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
          ci_poller: fn [^identifier], _opts ->
            {:ok,
             %{
               results: [
                 %{
                   target: identifier,
                   decision: :passed,
                   head_sha: "stale-head",
                   pr_number: 1_237
                 }
               ],
               errors: []
             }}
          end
        )

      receive_barrier({:ci_watcher_update_opts, ^identifier, "in-progress", [expected_state: "ci-wait"]})

      assert state.ci_lifecycle.approved_heads == %{}
      assert state.running == %{}
    end

    test "an approved head stays in human review after the agent handoff and an orchestrator restart" do
      identifier = "ci-restart"
      waiting_issue = %Issue{id: identifier, identifier: identifier, state: "ci-wait", title: "Restart-safe CI"}

      state =
        CiLifecycle.poll_github_ci(empty_orchestrator_state(),
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [waiting_issue]} end,
          ci_poller: fn [^identifier], _opts ->
            {:ok, %{results: [%{target: identifier, decision: :passed, head_sha: "approved-head"}], errors: []}}
          end
        )

      receive_barrier({:ci_watcher_update, ^identifier, "in-progress"})
      assert state.ci_lifecycle.approved_heads == %{"ci-restart" => "approved-head"}

      persisted = CIApprovalStore.load()

      restarted_state = %{
        empty_orchestrator_state()
        | ci_lifecycle: persisted
      }

      review_issue = %{waiting_issue | state: "human-review"}

      state =
        CiLifecycle.poll_github_ci(restarted_state,
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [review_issue]} end,
          ci_poller: fn [^identifier], _opts ->
            {:ok, %{results: [%{target: identifier, decision: :pending, head_sha: "approved-head"}], errors: []}}
          end
        )

      # The second synchronous poll has completed its tracker decision.
      refute_received {:ci_watcher_update, ^identifier, "ci-wait"}
      assert state.ci_lifecycle.approved_heads == %{"ci-restart" => "approved-head"}
    end

    test "approval store fails closed for valid JSON with malformed lifecycle fields" do
      File.write!(CIApprovalStore.path_for(), ~s({"approved_heads":null,"test_failure_heads":["not-a-map"]}))

      assert CIApprovalStore.load() == %{
               approved_heads: %{},
               passed_heads: %{},
               test_failure_heads: %{},
               base_repair_invalidations: %{}
             }
    end

    test "persists base repair invalidation and supplies it to later CI polls" do
      identifier = "ci-base-repair"
      issue = %Issue{id: identifier, identifier: identifier, state: "ci-wait", title: "Retarget CI"}

      invalidation = %{
        head_sha: "repaired-head",
        repaired_at: 1_784_070_000,
        repair_state: :repaired
      }

      state =
        CiLifecycle.poll_github_ci(empty_orchestrator_state(),
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
          ci_poller: fn [^identifier], opts ->
            assert Keyword.get(opts, :base_repair_invalidations) == %{}

            {:ok,
             %{
               results: [
                 %{
                   target: identifier,
                   decision: :failed,
                   head_sha: "repaired-head",
                   pr_number: 1174,
                   base_repair_invalidation: invalidation,
                   failures: [%{name: "pull request base branch", result: "repaired"}]
                 }
               ],
               errors: []
             }}
          end
        )

      assert state.ci_lifecycle.base_repair_invalidations == %{identifier => invalidation}

      assert %{
               base_repair_invalidations: %{^identifier => ^invalidation}
             } = persisted = CIApprovalStore.load()

      restarted_state = %{
        empty_orchestrator_state()
        | ci_lifecycle:
            persisted
            |> Map.put(:poll_cache, %{})
            |> Map.put(:rewakes, %{})
      }

      state =
        CiLifecycle.poll_github_ci(restarted_state,
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
          ci_poller: fn [^identifier], opts ->
            assert Keyword.fetch!(opts, :base_repair_invalidations) == %{identifier => invalidation}

            {:ok,
             %{
               results: [
                 %{
                   target: identifier,
                   decision: :pending,
                   head_sha: "repaired-head",
                   pending_reason: :base_repair_ci_revalidation_required
                 }
               ],
               errors: []
             }}
          end
        )

      assert state.ci_lifecycle.base_repair_invalidations == %{identifier => invalidation}
    end
  end
end

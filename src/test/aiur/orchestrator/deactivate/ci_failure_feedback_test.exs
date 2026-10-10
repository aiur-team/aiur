defmodule Aiur.Orchestrator.Deactivate.CiFailureFeedbackTest do
  use Aiur.TestSupport

  alias Aiur.CIApprovalStore
  alias Aiur.Events.{Exchange, SubscriptionStore}
  alias Aiur.Issue
  alias Aiur.Orchestrator
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

    test "failing CI changes the ticket to rework before publishing a sanitized wake event" do
      identifier = "823"
      topic = "ticket.#{identifier}.ci.failed"
      issue = %Issue{id: identifier, identifier: identifier, state: "ci-wait", title: "CI gate"}
      :ok = Exchange.subscribe(topic)

      try do
        CiLifecycle.poll_github_ci(empty_orchestrator_state(),
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
          ci_poller: fn [^identifier], _opts ->
            {:ok,
             %{
               results: [
                 %{
                   target: identifier,
                   decision: :failed,
                   head_sha: "failed-head",
                   pr_number: 823,
                   failures: [
                     %{name: "check without excerpt", result: "failure"},
                     %{
                       name: "lint <unsafe>",
                       excerpt: "ghp_" <> String.duplicate("X", 40),
                       result: "failure"
                     }
                   ]
                 }
               ],
               errors: []
             }}
          end
        )

        receive_barrier({:ci_watcher_update, ^identifier, "rework"})

        receive_barrier(
          {:event,
           %{
             topic: ^topic,
             source: :github,
             message: message,
             failure_excerpt: excerpt,
             checks: [_, %{name: "lint &lt;unsafe&gt;"}]
           }}
        )

        assert excerpt =~ "[REDACTED:ghp]"
        assert message =~ "lint &lt;unsafe&gt;"
        assert message =~ "Failure excerpt: [REDACTED:ghp]"
      after
        if Process.whereis(Exchange), do: Exchange.unsubscribe(topic)
      end
    end

    test "CI failure subscribes an absent runner before publishing its wake event" do
      identifier = "ci-no-runner-#{System.unique_integer([:positive])}"
      issue = %Issue{id: identifier, identifier: identifier, state: "ci-wait", title: "Recover CI"}
      test_pid = self()

      SubscriptionStore.set_enqueue_fn(fn target, event ->
        send(test_pid, {:ci_failure_enqueued, target, event})
        :ok
      end)

      on_exit(fn ->
        SubscriptionStore.set_enqueue_fn(nil)
        SubscriptionStore.stop(identifier)
      end)

      CiLifecycle.poll_github_ci(empty_orchestrator_state(),
        ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
        ci_poller: fn [^identifier], _opts ->
          {:ok,
           %{
             results: [
               %{
                 target: identifier,
                 decision: :failed,
                 head_sha: "failed-head",
                 pr_number: 828,
                 failures: [%{name: "lint", result: "failure", excerpt: "lint failed"}]
               }
             ],
             errors: []
           }}
        end
      )

      topics = SubscriptionStore.snapshot(identifier).subscribed_to |> Enum.map(& &1["topic"])
      ci_failure_topic = "ticket.#{identifier}.ci.failed"

      assert ci_failure_topic in topics
      receive_barrier({:ci_failure_enqueued, ^identifier, %{topic: ^ci_failure_topic}})
    end

    test "stale repeated CI failures publish one wake event per head" do
      identifier = "ci-dedup-#{System.unique_integer([:positive])}"
      topic = "ticket.#{identifier}.ci.failed"
      issue = %Issue{id: identifier, identifier: identifier, state: "ci-wait", title: "Deduplicate CI"}
      {:ok, failure_order} = Agent.start_link(fn -> 0 end)
      :ok = Exchange.subscribe(topic)

      poll = fn ->
        CiLifecycle.poll_github_ci(empty_orchestrator_state(),
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
          ci_poller: fn [^identifier], _opts ->
            failures =
              Agent.get_and_update(failure_order, fn
                0 ->
                  {[
                     %{name: "lint", result: "failure", excerpt: "lint failed"},
                     %{name: "test", result: "timed_out", excerpt: "test timed out"}
                   ], 1}

                count ->
                  {[
                     %{name: "test", result: "timed_out", excerpt: "test timed out"},
                     %{name: "lint", result: "failure", excerpt: "lint failed"}
                   ], count + 1}
              end)

            {:ok,
             %{
               results: [
                 %{
                   target: identifier,
                   decision: :failed,
                   head_sha: "same-failed-head",
                   pr_number: 829,
                   failures: failures
                 }
               ],
               errors: []
             }}
          end
        )
      end

      try do
        poll.()
        receive_barrier({:event, %{topic: ^topic}})

        poll.()
        # The second poll returns only after the deduplication decision and any
        # resulting publish have completed.
        refute_received {:event, %{topic: ^topic}}
      after
        if Process.whereis(Exchange), do: Exchange.unsubscribe(topic)
        SubscriptionStore.stop(identifier)
      end
    end

    test "test-only CI failure is surfaced to a ci-wait agent for judgment" do
      identifier = "826"

      issue = %Issue{
        id: identifier,
        identifier: identifier,
        state: "ci-wait",
        title: "Fix CI",
        tracker_identity: tracker_identity(identifier)
      }

      agent_pid = control_test_agent(self())

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
      end)

      stale_issue = %Issue{
        id: identifier,
        identifier: identifier,
        state: "ci-wait",
        title: "Hold CI",
        tracker_identity: tracker_identity(identifier)
      }

      state =
        human_review_running_state(identifier, agent_pid)
        |> put_in([Access.key(:running), identifier, :issue], stale_issue)
        |> put_in([Access.key(:running), identifier, :control], confirmed_control(:paused))
        |> put_in([Access.key(:running), identifier, :paused_reason], :ci_wait)
        |> put_in([Access.key(:running), identifier, :paused_at], DateTime.utc_now())
        |> put_in([Access.key(:ci_lifecycle), :test_failure_heads], %{identifier => "failed-head"})

      state =
        CiLifecycle.poll_github_ci(state,
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
          ci_poller: fn [^identifier], _opts ->
            {:ok,
             %{
               results: [
                 %{
                   target: identifier,
                   decision: :failed,
                   head_sha: "failed-head",
                   pr_number: 826,
                   failures: [%{name: "test", result: "failure", excerpt: "failed assertion"}]
                 }
               ],
               errors: []
             }}
          end
        )

      rework_issue = %{issue | state: "rework"}
      Application.put_env(:aiur, :ci_watcher_issues, [rework_issue])

      assert {:noreply, state} =
               Orchestrator.handle_info(
                 {:event, %{topic: "ticket.#{identifier}.ci.failed"}},
                 state
               )

      receive_barrier({:ci_wait_control, {:resume_agent, _request_id, 101}})
      receive_barrier({:ci_watcher_update, ^identifier, "rework"})

      entry = Map.fetch!(state.running, identifier)
      assert get_in(entry, [:control, :status]) == :paused
      assert entry.paused_reason == :ci_wait
      assert entry.issue.state == "rework"
    end

    test "test-only CI failure is retried once before rework" do
      identifier = "ci-test-retry"
      issue = %Issue{id: identifier, identifier: identifier, state: "ci-wait", title: "Retry test CI"}
      agent_pid = control_test_agent(self())

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
      end)

      state =
        human_review_running_state(identifier, agent_pid)
        |> put_in([Access.key(:running), identifier, :issue], issue)
        |> put_in([Access.key(:running), identifier, :control], confirmed_control(:paused))
        |> put_in([Access.key(:running), identifier, :paused_reason], :label_override)
        |> put_in([Access.key(:running), identifier, :paused_at], DateTime.utc_now())

      poll = fn state ->
        CiLifecycle.poll_github_ci(state,
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
          ci_poller: fn [^identifier], _opts ->
            {:ok,
             %{
               results: [
                 %{
                   target: identifier,
                   decision: :failed,
                   head_sha: "test-retry-head",
                   pr_number: 826,
                   failures: [%{name: "test", result: "failure", excerpt: "failed assertion"}]
                 }
               ],
               errors: []
             }}
          end
        )
      end

      state = poll.(state)

      # poll/1 returns after both the resume and tracker-update decisions.
      control_agent_barrier(agent_pid)
      refute_received {:ci_wait_control, {:resume_agent, _request_id}}
      refute_received {:ci_watcher_update, ^identifier, "rework"}
      assert state.ci_lifecycle.test_failure_heads == %{identifier => "test-retry-head"}

      entry = Map.fetch!(state.running, identifier)
      assert get_in(entry, [:control, :status]) == :paused
      assert entry.paused_reason == :label_override
      assert entry.issue.state == "ci-wait"

      persisted = CIApprovalStore.load()
      state = %{state | ci_lifecycle: persisted}

      state = poll.(state)

      # The second synchronous poll has completed its resume decision.
      control_agent_barrier(agent_pid)
      refute_received {:ci_wait_control, {:resume_agent, _request_id}}
      receive_barrier({:ci_watcher_update, ^identifier, "rework"})
      assert state.ci_lifecycle.test_failure_heads == %{}
    end

    test "CI poll failure respects a newly applied operator pause" do
      identifier = "ci-poll-paused"

      issue = %Issue{
        id: identifier,
        identifier: identifier,
        state: "ci-wait",
        title: "Hold CI",
        paused: true,
        labels: ["agent:ci-wait", "agent:paused"]
      }

      agent_pid = control_test_agent(self())

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
      end)

      stale_issue = %Issue{id: identifier, identifier: identifier, state: "ci-wait", title: "Hold CI"}

      state =
        human_review_running_state(identifier, agent_pid)
        |> put_in([Access.key(:running), identifier, :issue], stale_issue)
        |> put_in([Access.key(:running), identifier, :control], confirmed_control(:paused))
        |> put_in([Access.key(:running), identifier, :paused_reason], :ci_wait)

      state =
        CiLifecycle.poll_github_ci(state,
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
          ci_poller: fn [^identifier], _opts ->
            {:ok,
             %{
               results: [
                 %{
                   target: identifier,
                   decision: :failed,
                   head_sha: "failed-head",
                   pr_number: 828,
                   failures: [%{name: "lint", result: "failure", excerpt: "lint failed"}]
                 }
               ],
               errors: []
             }}
          end
        )

      receive_barrier({:ci_watcher_update, ^identifier, "rework"})
      # poll_github_ci/2 returns after reconciling the fresh pause.
      control_agent_barrier(agent_pid)
      refute_received {:ci_wait_control, {:resume_agent, _request_id}}

      entry = Map.fetch!(state.running, identifier)
      assert get_in(entry, [:control, :status]) == :paused
      assert entry.paused_reason == :ci_wait
      assert entry.issue.state == "rework"
      assert entry.issue.paused
    end

    test "CI poll prunes lifecycle markers for tickets no longer awaiting CI" do
      :ok = CIApprovalStore.save(%{"old-review" => "old-head"}, %{"old-wait" => "failed-head"})

      state = %{
        empty_orchestrator_state()
        | ci_lifecycle: %{
            approved_heads: %{"old-review" => "old-head"},
            test_failure_heads: %{"old-wait" => "failed-head"},
            poll_cache: %{"old-review" => %{decision: :passed}}
          }
      }

      state =
        CiLifecycle.poll_github_ci(state,
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, []} end,
          ci_poller: fn [], _opts -> {:ok, %{results: [], errors: []}} end
        )

      assert state.ci_lifecycle.approved_heads == %{}
      assert state.ci_lifecycle.test_failure_heads == %{}
      assert state.ci_lifecycle.poll_cache == %{}

      assert CIApprovalStore.load() == %{
               approved_heads: %{},
               passed_heads: %{},
               test_failure_heads: %{},
               base_repair_invalidations: %{}
             }
    end
  end
end

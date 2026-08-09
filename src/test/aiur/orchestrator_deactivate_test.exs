defmodule Aiur.OrchestratorDeactivateTest do
  use Aiur.TestSupport

  alias Aiur.AgentPubSub
  alias Aiur.AgentQueueStore
  alias Aiur.CIApprovalStore
  alias Aiur.Events.{BranchRefStore, Exchange, Publisher, SubscriptionStore}
  alias Aiur.GitHub.CodeOwners
  alias Aiur.Issue
  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{CiLifecycle, CommandScan, CommentPolling, Dispatcher, DispatchPolicy, State}
  alias Aiur.Orchestrator.{EventTopics, PauseResume, PrAnchored, PushRouting, Reconciler}
  alias Aiur.Orchestrator.{RuntimeWatchdog, Slots, StatusReport}
  alias Aiur.SessionHandle
  alias Aiur.TrackerIdentity

  @pgrep_skip_reason Aiur.TestSupport.pgrep_skip_reason()

  defmodule ErrorLinearClient do
    def fetch_issue_states_by_ids(_issue_ids), do: {:error, :tracker_down}

    def graphql(query, %{"issueId" => _issue_id, "stateName" => "rework"})
        when is_binary(query) do
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "team" => %{"states" => %{"nodes" => [%{"id" => "state-rework"}]}}
           }
         }
       }}
    end

    def graphql(query, %{issueId: _issue_id, stateName: "rework"})
        when is_binary(query) do
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "team" => %{"states" => %{"nodes" => [%{"id" => "state-rework"}]}}
           }
         }
       }}
    end

    def graphql(query, %{"issueId" => _issue_id, "stateId" => "state-rework"})
        when is_binary(query) do
      {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
    end

    def graphql(query, %{issueId: _issue_id, stateId: "state-rework"})
        when is_binary(query) do
      {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
    end
  end

  defmodule FlakyReworkGitHubClient do
    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}
    def fetch_candidate_issues, do: {:ok, []}

    def update_issue_state(issue_id, state_name) do
      if self() == Application.get_env(:aiur, :flaky_rework_owner) do
        recipient = Application.get_env(:aiur, :flaky_rework_recipient)
        pid = Application.fetch_env!(:aiur, :flaky_rework_agent)

        if is_pid(recipient) do
          send(recipient, {:flaky_rework_update, issue_id, state_name})
        end

        Agent.get_and_update(pid, fn
          [result | rest] -> {result, rest}
          [] -> {:ok, []}
        end)
      else
        {:error, :unexpected_test_caller}
      end
    end
  end

  defmodule PauseOverrideGitHubClient do
    def remove_label(issue_id, label) do
      recipient = Application.get_env(:aiur, :pause_override_recipient)

      if is_pid(recipient), do: send(recipient, {:pause_override_remove_label, issue_id, label})

      Application.get_env(:aiur, :pause_override_remove_result, :ok)
    end
  end

  defmodule HumanReviewGuardGitHubClient do
    def verify_human_review_ready(issue_id) do
      if is_pid(recipient()), do: send(recipient(), {:human_review_verify, issue_id})
      Application.get_env(:aiur, :human_review_ready_result, :ok)
    end

    def update_issue_state(issue_id, state_name) do
      if is_pid(recipient()), do: send(recipient(), {:human_review_update, issue_id, state_name})
      :ok
    end

    defp recipient, do: Application.get_env(:aiur, :human_review_guard_recipient)
  end

  defmodule DirectDispatchGitHubClient do
    def update_issue_state(issue_id, state_name) do
      if is_pid(recipient()),
        do: send(recipient(), {:direct_dispatch_update, issue_id, state_name})

      :ok
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(recipient(), {:direct_dispatch_fetch, issue_ids})

      issues =
        :aiur
        |> Application.fetch_env!(:direct_dispatch_issues)
        |> Enum.filter(&(&1.id in issue_ids))

      {:ok, issues}
    end

    def fetch_candidate_issues do
      send(recipient(), :direct_dispatch_candidate_fetch)
      {:ok, []}
    end

    defp recipient, do: Application.get_env(:aiur, :direct_dispatch_recipient)
  end

  defmodule CIWatcherGitHubClient do
    def update_issue_state(issue_id, state_name) do
      if is_pid(recipient()), do: send(recipient(), {:ci_watcher_update, issue_id, state_name})
      :ok
    end

    def update_issue_state(issue_id, state_name, opts) do
      if is_pid(recipient()), do: send(recipient(), {:ci_watcher_update_opts, issue_id, state_name, opts})
      if is_pid(recipient()), do: send(recipient(), {:ci_watcher_update, issue_id, state_name})
      Application.get_env(:aiur, :ci_watcher_update_result, :ok)
    end

    def fetch_issue_states_by_ids(issue_ids) do
      issues = Application.get_env(:aiur, :ci_watcher_issues, [])
      {:ok, Enum.filter(issues, &(&1.id in issue_ids))}
    end

    defp recipient, do: Application.get_env(:aiur, :ci_watcher_recipient)
  end

  describe "reconcile with nil / non-binary issue state (crash regression)" do
    # Live crash signature (from production logs):
    #   ** (FunctionClauseError) no function clause matching in
    #      Aiur.Orchestrator.active_issue_state?(nil, MapSet.new(...))
    #   ** (FunctionClauseError) no function clause matching in
    #      Aiur.Orchestrator.normalize_issue_state(nil)
    #
    # GitHub poll can return an Issue with state=nil whenever no
    # `agent:*` label is set. Each predicate guarded by
    # `when is_binary(state_name)` MUST also accept the non-binary
    # case or the entire orchestrator GenServer crashes on the next
    # reconcile/poll cycle.

    test "nil issue.state does not crash reconcile_issue_state cond" do
      issue_id = "issue-nil-state"
      issue_identifier = "NS-1"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      # State derives nil whenever no agent:* label is present on
      # the polled issue.
      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: nil,
        title: "label-less issue",
        description: "",
        labels: []
      }

      # Must NOT raise FunctionClauseError. State unchanged is fine —
      # the orchestrator just leaves the issue alone until a recognized
      # label appears.
      result = Reconciler.reconcile_running_issue_states([issue], state)

      assert result == state
    end

    test "empty string issue.state also survives" do
      issue_id = "issue-empty-state"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: "ES-1",
        state: "",
        title: "blank state",
        description: "",
        labels: []
      }

      result = Reconciler.reconcile_running_issue_states([issue], state)
      assert result == state
    end
  end

  describe "GitHub CI feedback poller" do
    setup do
      previous_client = Application.get_env(:aiur, :github_client_module)
      previous_recipient = Application.get_env(:aiur, :ci_watcher_recipient)
      previous_issues = Application.get_env(:aiur, :ci_watcher_issues)
      previous_update_result = Application.get_env(:aiur, :ci_watcher_update_result)
      previous_ci_approval_store_path = Application.get_env(:aiur, :ci_approval_store_path)
      ci_approval_store_path = Path.join(System.tmp_dir!(), "aiur_ci_approvals_#{System.unique_integer([:positive])}.json")

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

      assert_receive {:ci_watcher_update, "821", "ci-wait"}
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

      refute_receive {:ci_watcher_update, ^identifier, "ci-wait"}, 100
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

      refute_receive {:ci_wait_control, {:pause_agent, _request_id}}
      refute_receive {:ci_watcher_update, ^identifier, "ci-wait"}

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

      assert_receive {:ci_watcher_update, ^identifier, "ci-wait"}
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

      assert_receive {:ci_watcher_update, "822", "in-progress"}
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

      assert_receive {:ci_watcher_update_opts, ^identifier, "in-progress", [expected_state: "ci-wait"]}

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

      assert_receive {:ci_watcher_update, ^identifier, "in-progress"}
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

      refute_receive {:ci_watcher_update, ^identifier, "ci-wait"}
      assert state.ci_lifecycle.approved_heads == %{"ci-restart" => "approved-head"}
    end

    test "approval store fails closed for valid JSON with malformed lifecycle fields" do
      File.write!(CIApprovalStore.path_for(), ~s({"approved_heads":null,"test_failure_heads":["not-a-map"]}))

      assert CIApprovalStore.load() == %{
               approved_heads: %{},
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

        assert_receive {:ci_watcher_update, ^identifier, "rework"}

        assert_receive {:event,
                        %{
                          topic: ^topic,
                          source: :github,
                          message: message,
                          failure_excerpt: excerpt,
                          checks: [_, %{name: "lint &lt;unsafe&gt;"}]
                        }},
                       500

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
      assert_receive {:ci_failure_enqueued, ^identifier, %{topic: ^ci_failure_topic}}, 500
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
        assert_receive {:event, %{topic: ^topic}}, 500

        poll.()
        refute_receive {:event, %{topic: ^topic}}, 200
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

      assert_receive {:ci_wait_control, {:resume_agent, _request_id, 101}}
      assert_receive {:ci_watcher_update, ^identifier, "rework"}

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

      refute_receive {:ci_wait_control, {:resume_agent, _request_id}}
      refute_receive {:ci_watcher_update, ^identifier, "rework"}
      assert state.ci_lifecycle.test_failure_heads == %{identifier => "test-retry-head"}

      entry = Map.fetch!(state.running, identifier)
      assert get_in(entry, [:control, :status]) == :paused
      assert entry.paused_reason == :label_override
      assert entry.issue.state == "ci-wait"

      persisted = CIApprovalStore.load()
      state = %{state | ci_lifecycle: persisted}

      state = poll.(state)

      refute_receive {:ci_wait_control, {:resume_agent, _request_id}}
      assert_receive {:ci_watcher_update, ^identifier, "rework"}
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

      assert_receive {:ci_watcher_update, ^identifier, "rework"}
      refute_receive {:ci_wait_control, {:resume_agent, _request_id}}

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
               test_failure_heads: %{},
               base_repair_invalidations: %{}
             }
    end

    test "CI failure topic parser accepts only ticket-local failure events" do
      assert {:ok, "824"} = EventTopics.parse_ci_failed_topic("ticket.824.ci.failed")

      for topic <- ["ticket.824.ci.passed", "ticket.824.ci.failed.extra", "ticket.824.pr.review_comment"] do
        assert :nomatch = EventTopics.parse_ci_failed_topic(topic)
      end
    end

    test "CI failure events do not resume an operator-paused runner" do
      identifier = "827"
      agent_pid = control_test_agent(self())

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
      end)

      state =
        human_review_running_state(identifier, agent_pid)
        |> put_in([Access.key(:running), identifier, :control], confirmed_control(:paused))
        |> put_in([Access.key(:running), identifier, :paused_reason], :label_override)

      assert {:noreply, next_state} =
               Orchestrator.handle_info(
                 {:event, %{topic: "ticket.#{identifier}.ci.failed"}},
                 state
               )

      refute_receive {:ci_wait_control, {:resume_agent, _request_id}}
      assert get_in(next_state.running[identifier], [:control, :status]) == :paused
      assert next_state.running[identifier].paused_reason == :label_override
    end

    test "CI pass events resume an eligible CI-wait runner in the active handoff state" do
      identifier = "ci-pass-event-wake"
      agent_pid = control_test_agent(self())

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
      end)

      active_issue = %Issue{
        id: identifier,
        identifier: identifier,
        state: "in-progress",
        tracker_identity: tracker_identity(identifier)
      }

      Application.put_env(:aiur, :ci_watcher_issues, [active_issue])

      state =
        human_review_running_state(identifier, agent_pid)
        |> put_in([Access.key(:running), identifier, :issue], active_issue)
        |> put_in([Access.key(:running), identifier, :control], confirmed_control(:paused))
        |> put_in([Access.key(:running), identifier, :paused_reason], :ci_wait)

      assert {:noreply, next_state} =
               Orchestrator.handle_info(
                 {:event, %{topic: "ticket.#{identifier}.ci.passed"}},
                 state
               )

      assert_receive {:ci_wait_control, {:resume_agent, _request_id, 101}}
      assert get_in(next_state.running[identifier], [:control, :status]) == :paused
      assert next_state.running[identifier].paused_reason == :ci_wait
    end

    test "CI failure events respect a fresh operator pause on a ci-wait runner" do
      identifier = "ci-event-fresh-pause"
      agent_pid = control_test_agent(self())

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
      end)

      paused_issue = %Issue{id: identifier, identifier: identifier, state: "rework", paused: true}
      Application.put_env(:aiur, :ci_watcher_issues, [paused_issue])

      state =
        human_review_running_state(identifier, agent_pid)
        |> put_in([Access.key(:running), identifier, :issue], paused_issue)
        |> put_in([Access.key(:running), identifier, :control], confirmed_control(:paused))
        |> put_in([Access.key(:running), identifier, :paused_reason], :ci_wait)

      assert {:noreply, next_state} =
               Orchestrator.handle_info(
                 {:event, %{topic: "ticket.#{identifier}.ci.failed"}},
                 state
               )

      refute_receive {:ci_wait_control, {:resume_agent, _request_id}}
      assert get_in(next_state.running[identifier], [:control, :status]) == :paused
      assert next_state.running[identifier].paused_reason == :ci_wait
    end

    test "a stale terminal event cannot resume a tracker-terminal CI-wait runner" do
      identifier = "ci-event-stale-terminal"
      agent_pid = control_test_agent(self())

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
      end)

      stale_issue = %Issue{id: identifier, identifier: identifier, state: "in-progress"}
      terminal_issue = %{stale_issue | state: "done"}
      Application.put_env(:aiur, :ci_watcher_issues, [terminal_issue])

      state =
        human_review_running_state(identifier, agent_pid)
        |> put_in([Access.key(:running), identifier, :issue], stale_issue)
        |> put_in([Access.key(:running), identifier, :control], confirmed_control(:paused))
        |> put_in([Access.key(:running), identifier, :paused_reason], :ci_wait)

      assert {:noreply, next_state} =
               Orchestrator.handle_info(
                 {:event, %{topic: "ticket.#{identifier}.ci.passed"}},
                 state
               )

      refute_receive {:ci_wait_control, {:resume_agent, _request_id}}
      assert next_state.running[identifier].control.status == :paused
      assert next_state.running[identifier].issue.state == "done"
    end

    test "a terminal event cannot resume a runner reassigned to another worker" do
      identifier = "ci-event-routed-away"
      agent_pid = control_test_agent(self())

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
      end)

      stale_issue = %Issue{id: identifier, identifier: identifier, state: "in-progress"}
      reassigned_issue = %{stale_issue | assigned_to_worker: false}
      Application.put_env(:aiur, :ci_watcher_issues, [reassigned_issue])

      state =
        human_review_running_state(identifier, agent_pid)
        |> put_in([Access.key(:running), identifier, :issue], stale_issue)
        |> put_in([Access.key(:running), identifier, :control], confirmed_control(:paused))
        |> put_in([Access.key(:running), identifier, :paused_reason], :ci_wait)

      assert {:noreply, next_state} =
               Orchestrator.handle_info(
                 {:event, %{topic: "ticket.#{identifier}.ci.passed"}},
                 state
               )

      refute_receive {:ci_wait_control, {:resume_agent, _request_id}}
      assert next_state.running[identifier].control.status == :paused
      refute next_state.running[identifier].issue.assigned_to_worker
    end

    test "a capacity-deferred terminal wake resumes after another slot opens" do
      identifier = "ci-event-capacity"
      agent_pid = control_test_agent(self())

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
      end)

      active_issue = %Issue{
        id: identifier,
        identifier: identifier,
        state: "in-progress",
        tracker_identity: tracker_identity(identifier)
      }

      other_issue = %Issue{id: "ci-other", identifier: "ci-other", state: "in-progress"}
      Application.put_env(:aiur, :ci_watcher_issues, [active_issue])

      state =
        human_review_running_state(identifier, agent_pid)
        |> put_in([Access.key(:running), identifier, :issue], active_issue)
        |> put_in([Access.key(:running), identifier, :control], confirmed_control(:paused))
        |> put_in([Access.key(:running), identifier, :paused_reason], :ci_wait)
        |> put_in([Access.key(:max_concurrent_agents)], 1)
        |> put_in(
          [Access.key(:running), other_issue.id],
          %{identifier: other_issue.identifier, issue: other_issue, control: %{status: :working}}
        )

      assert {:noreply, deferred_state} =
               Orchestrator.handle_info(
                 {:event, %{topic: "ticket.#{identifier}.ci.passed"}},
                 state
               )

      refute_receive {:ci_wait_control, {:resume_agent, _request_id}}
      assert deferred_state.running[identifier].control.status == :paused

      resumed_state =
        deferred_state
        |> update_in([Access.key(:running)], &Map.delete(&1, other_issue.id))
        |> Reconciler.maybe_reactivate_or_refresh(active_issue)

      assert_receive {:ci_wait_control, {:resume_agent, _request_id, 101}}
      assert resumed_state.running[identifier].control.status == :paused
      assert resumed_state.running[identifier].paused_reason == :ci_wait
    end
  end

  describe "reconcile on agent:human-review label" do
    test "human-review state keeps the running entry, kills the task, marks :deactivated" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-deactivate-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-deactivate-1"
      issue_identifier = "DA-1"
      workspace = Path.join(test_root, issue_identifier)
      previous_log_file = Application.get_env(:aiur, :log_file)

      try do
        Application.put_env(:aiur, :log_file, Path.join([test_root, "log", "agent.md"]))

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        File.mkdir_p!(workspace)
        :ok = SessionHandle.save(issue_identifier, %{backend: "codex", thread_id: "thread-keep"})

        agent_pid =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: agent_pid,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "in-progress", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "human-review",
          title: "PR up for review",
          description: "",
          labels: []
        }

        updated_state = Reconciler.reconcile_running_issue_states([issue], state)

        # Entry survives — this is the whole point of the deactivate path.
        assert Map.has_key?(updated_state.running, issue_id)
        assert MapSet.member?(updated_state.claimed, issue_id)

        # Codex task pid was killed (mirror terminate_running_issue's teardown).
        refute Process.alive?(agent_pid)

        # Entry shape: pid cleared, control.status flipped to :deactivated.
        entry = Map.fetch!(updated_state.running, issue_id)
        assert is_nil(entry.pid)
        assert get_in(entry, [:control, :status]) == :deactivated

        # Workspace not cleaned up (deactivation is non-terminal).
        assert File.exists?(workspace)
        assert {:ok, %{thread_id: "thread-keep"}} = SessionHandle.load(issue_identifier, "codex")
      after
        restore_application_env(:log_file, previous_log_file)
        File.rm_rf(test_root)
      end
    end

    test "human-review on an already-deactivated entry is a no-op" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-deactivate-noop-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-deactivate-2"
      issue_identifier = "DA-2"

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: nil,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "human-review", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :deactivated}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "human-review",
          title: "PR up for review",
          description: "",
          labels: []
        }

        updated_state = Reconciler.reconcile_running_issue_states([issue], state)

        # Same shape after the second observation — no spurious task kill,
        # no double-deactivate side effect.
        entry = Map.fetch!(updated_state.running, issue_id)
        assert is_nil(entry.pid)
        assert get_in(entry, [:control, :status]) == :deactivated
      after
        File.rm_rf(test_root)
      end
    end

    test "human-review with unverified review threads is reverted to rework instead of deactivated" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-human-review-guard-#{System.unique_integer([:positive])}"
        )

      issue_id = "57"
      issue_identifier = "57"
      previous_github_client = Application.get_env(:aiur, :github_client_module)
      previous_guard_recipient = Application.get_env(:aiur, :human_review_guard_recipient)
      previous_ready_result = Application.get_env(:aiur, :human_review_ready_result)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "github",
          workspace_root: test_root,
          tracker_repo: "owner/repo",
          tracker_label_prefix: "agent",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :github_client_module, HumanReviewGuardGitHubClient)
        Application.put_env(:aiur, :human_review_guard_recipient, self())

        Application.put_env(
          :aiur,
          :human_review_ready_result,
          {:error, {:unverified_review_threads, %{count: 1, review_thread_ids: ["PRRT_missing"]}}}
        )

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: agent_pid,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "in-progress", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "human-review",
          title: "PR up for review",
          description: "",
          labels: []
        }

        updated_state = Reconciler.reconcile_running_issue_states([issue], state)

        assert_receive {:human_review_verify, ^issue_id}
        assert_receive {:human_review_update, ^issue_id, "rework"}
        assert Process.alive?(agent_pid)

        entry = Map.fetch!(updated_state.running, issue_id)
        assert entry.pid == agent_pid
        assert entry.issue.state == "rework"
        assert get_in(entry, [:control, :status]) == :working
      after
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
        restore_application_env(:github_client_module, previous_github_client)
        restore_application_env(:human_review_guard_recipient, previous_guard_recipient)
        restore_application_env(:human_review_ready_result, previous_ready_result)
        File.rm_rf(test_root)
      end
    end

    test "human-review with a transient verification error is left for a later poll" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-human-review-transient-#{System.unique_integer([:positive])}"
        )

      issue_id = "58"
      issue_identifier = "58"
      previous_github_client = Application.get_env(:aiur, :github_client_module)
      previous_guard_recipient = Application.get_env(:aiur, :human_review_guard_recipient)
      previous_ready_result = Application.get_env(:aiur, :human_review_ready_result)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "github",
          workspace_root: test_root,
          tracker_repo: "owner/repo",
          tracker_label_prefix: "agent",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :github_client_module, HumanReviewGuardGitHubClient)
        Application.put_env(:aiur, :human_review_guard_recipient, self())

        Application.put_env(
          :aiur,
          :human_review_ready_result,
          {:error, {:github, :rate_limited, %{status: 429}}}
        )

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: agent_pid,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "in-progress", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "human-review",
          title: "PR up for review",
          description: "",
          labels: []
        }

        updated_state = Reconciler.reconcile_running_issue_states([issue], state)

        assert_receive {:human_review_verify, ^issue_id}
        refute_received {:human_review_update, ^issue_id, "rework"}
        assert Process.alive?(agent_pid)

        entry = Map.fetch!(updated_state.running, issue_id)
        assert entry.pid == agent_pid
        assert entry.issue.state == "in-progress"
        assert get_in(entry, [:control, :status]) == :working
      after
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
        restore_application_env(:github_client_module, previous_github_client)
        restore_application_env(:human_review_guard_recipient, previous_guard_recipient)
        restore_application_env(:human_review_ready_result, previous_ready_result)
        File.rm_rf(test_root)
      end
    end

    test "human-review with transient GraphQL verification errors is left for a later poll" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-human-review-graphql-transient-#{System.unique_integer([:positive])}"
        )

      previous_github_client = Application.get_env(:aiur, :github_client_module)
      previous_guard_recipient = Application.get_env(:aiur, :human_review_guard_recipient)
      previous_ready_result = Application.get_env(:aiur, :human_review_ready_result)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "github",
          workspace_root: test_root,
          tracker_repo: "owner/repo",
          tracker_label_prefix: "agent",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :github_client_module, HumanReviewGuardGitHubClient)
        Application.put_env(:aiur, :human_review_guard_recipient, self())

        transient_errors = [
          {"58", [%{"type" => "RATE_LIMITED", "message" => "secondary rate limit"}]},
          {"59", [%{"type" => "INTERNAL", "message" => "server error"}]},
          {"60", [%{"extensions" => %{"code" => "INTERNAL_SERVER_ERROR"}}]},
          {"61", [%{type: :SERVICE_UNAVAILABLE}]}
        ]

        for {issue_id, errors} <- transient_errors do
          agent_pid =
            spawn(fn ->
              receive do
                :stop -> :ok
              end
            end)

          try do
            Application.put_env(
              :aiur,
              :human_review_ready_result,
              {:error, {:github_graphql_errors, errors}}
            )

            state = human_review_running_state(issue_id, agent_pid)
            issue = human_review_issue(issue_id)

            updated_state = Reconciler.reconcile_running_issue_states([issue], state)

            assert_receive {:human_review_verify, ^issue_id}
            refute_received {:human_review_update, ^issue_id, "rework"}
            assert Process.alive?(agent_pid)

            entry = Map.fetch!(updated_state.running, issue_id)
            assert entry.pid == agent_pid
            assert entry.issue.state == "in-progress"
            assert get_in(entry, [:control, :status]) == :working
          after
            if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
          end
        end
      after
        restore_application_env(:github_client_module, previous_github_client)
        restore_application_env(:human_review_guard_recipient, previous_guard_recipient)
        restore_application_env(:human_review_ready_result, previous_ready_result)
        File.rm_rf(test_root)
      end
    end

    test "human-review with a non-transient GraphQL verification error reverts to rework" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-human-review-graphql-permanent-#{System.unique_integer([:positive])}"
        )

      issue_id = "62"
      previous_github_client = Application.get_env(:aiur, :github_client_module)
      previous_guard_recipient = Application.get_env(:aiur, :human_review_guard_recipient)
      previous_ready_result = Application.get_env(:aiur, :human_review_ready_result)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "github",
          workspace_root: test_root,
          tracker_repo: "owner/repo",
          tracker_label_prefix: "agent",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :github_client_module, HumanReviewGuardGitHubClient)
        Application.put_env(:aiur, :human_review_guard_recipient, self())

        Application.put_env(
          :aiur,
          :human_review_ready_result,
          {:error, {:github_graphql_errors, [%{"type" => "FORBIDDEN", "message" => "denied"}]}}
        )

        state = human_review_running_state(issue_id, agent_pid)
        issue = human_review_issue(issue_id)

        updated_state = Reconciler.reconcile_running_issue_states([issue], state)

        assert_receive {:human_review_verify, ^issue_id}
        assert_receive {:human_review_update, ^issue_id, "rework"}
        assert Process.alive?(agent_pid)

        entry = Map.fetch!(updated_state.running, issue_id)
        assert entry.pid == agent_pid
        assert entry.issue.state == "rework"
        assert get_in(entry, [:control, :status]) == :working
      after
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
        restore_application_env(:github_client_module, previous_github_client)
        restore_application_env(:human_review_guard_recipient, previous_guard_recipient)
        restore_application_env(:human_review_ready_result, previous_ready_result)
        File.rm_rf(test_root)
      end
    end

    test "terminate (terminal label) also broadcasts aiur_turn_done for every active chat stream" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-terminate-stream-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-terminate-stream"
      issue_identifier = "TS-1"
      turn_a = "t-term-a"
      turn_b = "t-term-b"

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        # Same two-stream prewarm-race shape as the deactivate test.
        ActiveTurns.put(issue_identifier, turn_a)
        ActiveTurns.put(issue_identifier, turn_b)

        :ok = AgentPubSub.subscribe_agent(issue_identifier)

        agent_pid =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: agent_pid,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "in-progress", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        # Terminal label → terminate_running_issue with cleanup_workspace=true
        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "done",
          title: "merged",
          description: "",
          labels: []
        }

        _ = Reconciler.reconcile_running_issue_states([issue], state)

        assert_receive {:aiur_turn_done, ^issue_identifier, ^turn_a, :terminal}, 500
        assert_receive {:aiur_turn_done, ^issue_identifier, ^turn_b, :terminal}, 500

        assert {:closed, :terminal} = ActiveTurns.lookup(issue_identifier, turn_a)
        assert {:closed, :terminal} = ActiveTurns.lookup(issue_identifier, turn_b)
      after
        File.rm_rf(test_root)
      end
    end

    test "deactivate broadcasts aiur_turn_done for every active chat-completion stream" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-deactivate-stream-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-deactivate-stream"
      issue_identifier = "DS-1"
      turn_a = "t-stream-a"
      turn_b = "t-stream-b"

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        # Simulate two pre-warmed chat completion SSE streams for the
        # same identifier (the real-world cause of the duplicate
        # "No turn activity" messages).
        ActiveTurns.put(issue_identifier, turn_a)
        ActiveTurns.put(issue_identifier, turn_b)

        :ok = AgentPubSub.subscribe_agent(issue_identifier)

        agent_pid =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: agent_pid,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "in-progress", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "human-review",
          title: "PR up for review",
          description: "",
          labels: []
        }

        _ = Reconciler.reconcile_running_issue_states([issue], state)

        # Both streams receive the close broadcast.
        assert_receive {:aiur_turn_done, ^issue_identifier, ^turn_a, :deactivated}, 500
        assert_receive {:aiur_turn_done, ^issue_identifier, ^turn_b, :deactivated}, 500

        # The ActiveTurns entries are marked closed so any late SSE
        # subscribe finalizes with the same reason instead of waiting
        # on the broadcast it missed.
        assert {:closed, :deactivated} = ActiveTurns.lookup(issue_identifier, turn_a)
        assert {:closed, :deactivated} = ActiveTurns.lookup(issue_identifier, turn_b)
      after
        File.rm_rf(test_root)
      end
    end

    test "terminal label still terminates and cleans workspace (not intercepted by deactivate)" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-deactivate-terminal-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-deactivate-3"
      issue_identifier = "DA-3"
      # Linear default config namespaces workspaces under <root>/<project_slug>/.
      workspace = Path.join([test_root, "project", issue_identifier])
      previous_log_file = Application.get_env(:aiur, :log_file)

      try do
        Application.put_env(:aiur, :log_file, Path.join([test_root, "log", "agent.md"]))

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        File.mkdir_p!(workspace)
        :ok = SessionHandle.save(issue_identifier, %{backend: "codex", thread_id: "thread-clear"})

        agent_pid =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: agent_pid,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "in-progress", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        # Terminal state — the deactivate branch must NOT intercept.
        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "done",
          title: "Closed",
          description: "",
          labels: []
        }

        updated_state = Reconciler.reconcile_running_issue_states([issue], state)

        refute Map.has_key?(updated_state.running, issue_id)
        refute MapSet.member?(updated_state.claimed, issue_id)
        refute Process.alive?(agent_pid)
        refute File.exists?(workspace)
        assert :none == SessionHandle.load(issue_identifier, "codex")
      after
        restore_application_env(:log_file, previous_log_file)
        File.rm_rf(test_root)
      end
    end
  end

  describe "Aiur.AgentEvents.state_emoji/1" do
    test ":deactivated maps to the 🏁 glyph" do
      assert Aiur.AgentEvents.state_emoji(:deactivated) == "🏁"
      assert Aiur.AgentEvents.state_emoji("deactivated") == "🏁"
    end

    test ":done still maps to 🏁 (existing semantic preserved)" do
      assert Aiur.AgentEvents.state_emoji(:done) == "🏁"
      assert Aiur.AgentEvents.state_emoji("done") == "🏁"
    end

    test ":sleeping maps to the 💤 glyph (idle stream-close)" do
      assert Aiur.AgentEvents.state_emoji(:sleeping) == "💤"
      assert Aiur.AgentEvents.state_emoji("sleeping") == "💤"
    end
  end

  describe "mark_sleeping flips control.status to :sleeping on idle stream-close" do
    test "a :working entry transitions to :sleeping" do
      issue_id = "issue-sleep-1"
      identifier = "SLEEP-1"

      state = sleeping_state(issue_id, identifier, :working)

      next = PushRouting.maybe_mark_sleeping(state, identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :sleeping
    end

    test "a :sleeping entry holds its slot (does not free capacity)" do
      issue_id = "issue-sleep-slot"
      identifier = "SLEEP-SLOT"

      state = sleeping_state(issue_id, identifier, :working)
      next = PushRouting.maybe_mark_sleeping(state, identifier)

      # :sleeping is neither :paused nor :deactivated, so it still counts
      # as an active slot-holder — the agent is mid-turn, just idle-streamed.
      assert Slots.slot_status(next).active == 1
    end

    test "no-op when the entry is :paused (don't override a more-specific state)" do
      issue_id = "issue-sleep-paused"
      identifier = "SLEEP-PAUSED"

      state = sleeping_state(issue_id, identifier, :paused)

      next = PushRouting.maybe_mark_sleeping(state, identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
    end

    test "no-op when the entry is :deactivated (don't wake the dead)" do
      issue_id = "issue-sleep-deact"
      identifier = "SLEEP-DEACT"

      state = sleeping_state(issue_id, identifier, :deactivated)

      next = PushRouting.maybe_mark_sleeping(state, identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :deactivated
    end

    test "no-op when the identifier isn't running" do
      state = sleeping_state("issue-sleep-x", "SLEEP-X", :working)
      assert ^state = PushRouting.maybe_mark_sleeping(state, "UNKNOWN")
    end

    test "the next turn's :worker_control_state :working flips 💤 back to 🟢" do
      issue_id = "issue-sleep-wake"
      identifier = "SLEEP-WAKE"

      slept =
        sleeping_state(issue_id, identifier, :working)
        |> PushRouting.maybe_mark_sleeping(identifier)

      assert get_in(slept.running, [issue_id, :control, :status]) == :sleeping

      {:noreply, woke} =
        Orchestrator.handle_info({:worker_control_state, issue_id, :working}, slept)

      assert get_in(woke.running, [issue_id, :control, :status]) == :working
    end

    test "the {:mark_sleeping, identifier} cast clause flips :working to :sleeping" do
      issue_id = "issue-sleep-cast"
      identifier = "SLEEP-CAST"

      state = sleeping_state(issue_id, identifier, :working)

      {:noreply, next} =
        Orchestrator.handle_cast({:mark_sleeping, identifier}, state)

      assert get_in(next.running, [issue_id, :control, :status]) == :sleeping
    end

    defp sleeping_state(issue_id, identifier, status) do
      %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: status}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }
    end
  end

  describe "agent:paused label override" do
    test "paused active issue is not a dispatch candidate" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: "issue-paused-candidate",
        identifier: "PAUSE-1",
        state: "todo",
        title: "Paused candidate",
        paused: true,
        labels: ["agent:todo", "agent:paused"]
      }

      refute DispatchPolicy.dispatch_candidate?(issue, state)
      refute DispatchPolicy.should_dispatch_issue?(issue, state)
    end

    test "running issue pauses with an alert when the override appears" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      issue_id = "issue-paused-running"
      identifier = "PAUSE-2"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: self(),
            ref: nil,
            identifier: identifier,
            issue: %Issue{
              id: issue_id,
              identifier: identifier,
              state: "in-progress",
              tracker_identity: tracker_identity(issue_id)
            },
            started_at: DateTime.utc_now(),
            control: confirmed_control(:working)
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      paused_issue = %Issue{
        id: issue_id,
        identifier: identifier,
        state: "in-progress",
        title: "Paused running",
        tracker_identity: tracker_identity(issue_id),
        paused: true,
        labels: ["agent:in-progress", "agent:paused"]
      }

      Publisher.set_tracked_fn(fn _ -> true end)
      divergence_topic = "ticket.#{identifier}.agent.attention.state_divergence"
      :ok = Exchange.subscribe(divergence_topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)

        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      next = Reconciler.reconcile_running_issue_states([paused_issue], state)

      assert_receive {:event, %{topic: ^divergence_topic} = event}
      assert event["reason"] =~ "local=working tracker=agent:paused"
      assert_receive {:pause_agent, request_id, 101}
      assert get_in(next.running, [issue_id, :control, :status]) == :working
      assert next.running[issue_id].pending_pause_reason == %{request_id: request_id, reason: :label_override}
      refute Map.has_key?(next.running[issue_id], :paused_reason)
      assert get_in(next.running, [issue_id, :issue, Access.key(:paused)]) == true
    end

    test "removing the override reports divergence, resumes, and returns the row to running" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        max_concurrent_agents: 2
      )

      issue_id = "issue-paused-resume"
      identifier = "PAUSE-3"
      paused_at = DateTime.add(DateTime.utc_now(), -10, :second)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: self(),
            ref: nil,
            identifier: identifier,
            issue: %Issue{
              id: issue_id,
              identifier: identifier,
              state: "in-progress",
              paused: true,
              tracker_identity: tracker_identity(issue_id)
            },
            started_at: DateTime.add(DateTime.utc_now(), -30, :second),
            paused_at: paused_at,
            paused_reason: :label_override,
            control: confirmed_control(:paused)
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 2
      }

      unpaused_issue = %Issue{
        id: issue_id,
        identifier: identifier,
        state: "in-progress",
        title: "Unpaused running",
        tracker_identity: tracker_identity(issue_id),
        paused: false,
        labels: ["agent:in-progress"]
      }

      Publisher.set_tracked_fn(fn _ -> true end)
      divergence_topic = "ticket.#{identifier}.agent.attention.state_divergence"
      :ok = Exchange.subscribe(divergence_topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)

        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      next = Reconciler.reconcile_running_issue_states([unpaused_issue], state)

      assert_receive {:event, %{topic: ^divergence_topic} = event}
      assert event["reason"] =~ "local=paused(label_override) tracker=agent:in-progress"

      assert_receive {:resume_agent, request_id, 101}
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
      assert get_in(next.running, [issue_id, :paused_reason]) == :label_override
      assert get_in(next.running, [issue_id, :issue, Access.key(:paused)]) == false

      assert {:noreply, resumed} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :working, %{request_id: request_id, generation: 101}},
                 next
               )

      assert resumed.running[issue_id].control.status == :working
      refute Map.has_key?(resumed.running[issue_id], :paused_reason)

      assert [%{state: :running, tracker_paused: false, reason: nil}] =
               StatusReport.agent_statuses(resumed, fn _timeout -> {:unavailable, nil} end)
    end

    test "resume clears a durable override regardless of the local pause reason and survives reconciliation" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      previous_recipient = Application.get_env(:aiur, :memory_tracker_recipient)
      Application.put_env(:aiur, :memory_tracker_recipient, self())

      on_exit(fn ->
        if previous_recipient,
          do: Application.put_env(:aiur, :memory_tracker_recipient, previous_recipient),
          else: Application.delete_env(:aiur, :memory_tracker_recipient)
      end)

      issue_id = "issue-paused-resume-clears-label"
      identifier = "PAUSE-RESUME"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: self(),
            ref: nil,
            identifier: identifier,
            issue: %Issue{
              id: issue_id,
              identifier: identifier,
              state: "in-progress",
              paused: true,
              labels: ["agent:in-progress", "agent:paused"],
              tracker_identity: tracker_identity(issue_id)
            },
            started_at: DateTime.add(DateTime.utc_now(), -30, :second),
            paused_reason: :operator_pause,
            control: confirmed_control(:paused)
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 2
      }

      assert {:reply, {:ok, :resumed}, next} = Orchestrator.handle_call({:resume_agent, identifier}, self(), state)
      assert_receive {:memory_tracker_remove_label, ^identifier, "agent:paused"}
      assert_receive {:resume_agent, request_id, 101}
      resumed = next.running[issue_id]
      assert resumed.control.status == :paused
      assert resumed.paused_reason == :operator_pause
      refute resumed.issue.paused
      refute "agent:paused" in resumed.issue.labels

      assert {:noreply, working} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :working, %{request_id: request_id, generation: 101}},
                 next
               )

      reconciled = Reconciler.reconcile_running_issue_states([working.running[issue_id].issue], working)

      assert reconciled.running[issue_id].control.status == :working
      refute Map.has_key?(reconciled.running[issue_id], :paused_reason)
      refute_receive {:pause_agent, _request_id, _generation}, 100
    end

    test "resume leaves the worker paused when clearing the override fails" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      previous_client = Application.get_env(:aiur, :github_client_module)
      previous_recipient = Application.get_env(:aiur, :pause_override_recipient)
      previous_result = Application.get_env(:aiur, :pause_override_remove_result)
      Application.put_env(:aiur, :github_client_module, PauseOverrideGitHubClient)
      Application.put_env(:aiur, :pause_override_recipient, self())
      Application.put_env(:aiur, :pause_override_remove_result, {:error, :unavailable})

      on_exit(fn ->
        restore_application_env(:github_client_module, previous_client)
        restore_application_env(:pause_override_recipient, previous_recipient)
        restore_application_env(:pause_override_remove_result, previous_result)
      end)

      issue_id = "issue-paused-resume-failure"
      identifier = "PAUSE-RESUME-FAILURE"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: self(),
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, identifier: identifier, state: "in-progress", paused: true, labels: ["agent:in-progress", "agent:paused"]},
            started_at: DateTime.add(DateTime.utc_now(), -30, :second),
            paused_reason: :operator_pause,
            control: %{status: :paused}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 2
      }

      assert {:reply, {:error, {:pause_override_clear_failed, :unavailable}}, next} =
               Orchestrator.handle_call({:resume_agent, identifier}, self(), state)

      assert_receive {:pause_override_remove_label, ^identifier, "agent:paused"}
      refute_receive {:resume_agent, _request_id}
      assert next.running[issue_id].control.status == :paused
      assert next.running[issue_id].issue.paused
    end

    test "resume clears the durable override before starting an idle ticket" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        max_concurrent_agents: 1
      )

      previous_recipient = Application.get_env(:aiur, :memory_tracker_recipient)
      Application.put_env(:aiur, :memory_tracker_recipient, self())

      on_exit(fn -> restore_application_env(:memory_tracker_recipient, previous_recipient) end)

      issue = %Issue{
        id: "issue-idle-paused-resume",
        identifier: "PAUSE-IDLE-RESUME",
        title: "Idle paused resume",
        state: "todo",
        paused: true,
        labels: ["agent:todo", "agent:paused"],
        tracker_identity: tracker_identity("issue-idle-paused-resume")
      }

      state = %Orchestrator.State{
        last_polled_issues: %{issue.id => issue},
        max_concurrent_agents: 1,
        effective_concurrent_agents: 1
      }

      assert {:reply, reply, next} = Orchestrator.handle_call({:resume_agent, issue.identifier}, self(), state)
      assert reply in [{:ok, :started}, {:error, :dispatch_failed}]
      assert_receive {:memory_tracker_remove_label, "PAUSE-IDLE-RESUME", "agent:paused"}
      refute next.last_polled_issues[issue.id].paused
      refute "agent:paused" in next.last_polled_issues[issue.id].labels
    end

    test "initial dispatch keeps paused active tickets suppressed" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      previous_recipient = Application.get_env(:aiur, :memory_tracker_recipient)
      previous_issues = Application.get_env(:aiur, :memory_tracker_issues)
      Application.put_env(:aiur, :memory_tracker_recipient, self())

      on_exit(fn ->
        restore_application_env(:memory_tracker_recipient, previous_recipient)
        restore_application_env(:memory_tracker_issues, previous_issues)
      end)

      issues =
        for state_name <- ["todo", "in-progress", "rework", "merging"] do
          %Issue{
            id: "issue-startup-paused-#{state_name}",
            identifier: "PAUSE-STARTUP-#{state_name}",
            state: state_name,
            title: "Paused #{state_name}",
            paused: true,
            labels: ["agent:#{state_name}", "agent:paused"]
          }
        end

      Application.put_env(:aiur, :memory_tracker_issues, issues)

      state = %State{
        initial_dispatch_cycle: true,
        max_concurrent_agents: 4,
        effective_concurrent_agents: 4
      }

      next = Dispatcher.maybe_dispatch(state)

      refute next.initial_dispatch_cycle
      assert next.running == %{}
      assert next.claimed == MapSet.new()
      refute_receive {:memory_tracker_remove_label, _, "agent:paused"}

      for issue <- issues do
        assert recovered = next.last_polled_issues[issue.id]
        assert recovered.paused
        assert "agent:paused" in recovered.labels

        unpaused_issue = %{issue | paused: false, labels: ["agent:#{issue.state}"]}

        assert DispatchPolicy.candidate_issue?(
                 unpaused_issue,
                 DispatchPolicy.active_state_set(),
                 DispatchPolicy.terminal_state_set()
               )
      end
    end

    test "removing the override does not resume a manually paused agent" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      issue_id = "issue-manual-paused"
      identifier = "PAUSE-4"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: self(),
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, identifier: identifier, state: "in-progress", paused: true},
            started_at: DateTime.add(DateTime.utc_now(), -30, :second),
            paused_at: DateTime.add(DateTime.utc_now(), -10, :second),
            control: %{status: :paused}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 2
      }

      unpaused_issue = %Issue{
        id: issue_id,
        identifier: identifier,
        state: "in-progress",
        title: "Still manually paused",
        paused: false,
        labels: ["agent:in-progress"]
      }

      next = Reconciler.reconcile_running_issue_states([unpaused_issue], state)

      refute_receive {:resume_agent, _request_id}, 100
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
      assert get_in(next.running, [issue_id, :issue, Access.key(:paused)]) == false
    end
  end

  describe "slot counting on the public status snapshot" do
    test "deactivated entries do not consume a slot in the (N/M) counter" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-slot-counting-#{System.unique_integer([:positive])}"
        )

      issue_working = "issue-slot-working"
      issue_paused = "issue-slot-paused"
      issue_deactivated = "issue-slot-deactivated"

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        running = %{
          issue_working => %{
            pid: self(),
            ref: nil,
            identifier: "SLOT-1",
            issue: %Issue{id: issue_working, state: "in-progress", identifier: "SLOT-1"},
            started_at: DateTime.utc_now(),
            control: %{status: :working}
          },
          issue_paused => %{
            pid: self(),
            ref: nil,
            identifier: "SLOT-2",
            issue: %Issue{id: issue_paused, state: "in-progress", identifier: "SLOT-2"},
            started_at: DateTime.utc_now(),
            control: %{status: :paused}
          },
          issue_deactivated => %{
            pid: nil,
            ref: nil,
            identifier: "SLOT-3",
            issue: %Issue{id: issue_deactivated, state: "human-review", identifier: "SLOT-3"},
            started_at: DateTime.utc_now(),
            control: %{status: :deactivated}
          }
        }

        state = %Orchestrator.State{
          running: running,
          claimed: MapSet.new(Map.keys(running)),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        # `active` counts entries holding a slot. After U3, that's
        # :working only — :paused holds a slot too today (existing
        # behaviour, exposed as `paused`), and :deactivated holds NONE.
        status = Slots.slot_status(state)

        assert status.active == 1
        assert status.paused == 1
      after
        File.rm_rf(test_root)
      end
    end

    test "all-:deactivated running map frees every slot" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-slot-all-deact-#{System.unique_integer([:positive])}"
        )

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        running =
          for n <- 1..3, into: %{} do
            id = "issue-deact-all-#{n}"

            {id,
             %{
               pid: nil,
               ref: nil,
               identifier: "ALL-#{n}",
               issue: %Issue{id: id, state: "human-review", identifier: "ALL-#{n}"},
               started_at: DateTime.utc_now(),
               control: %{status: :deactivated}
             }}
          end

        state = %Orchestrator.State{
          running: running,
          claimed: MapSet.new(Map.keys(running)),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        status = Slots.slot_status(state)

        assert status.active == 0
        assert status.paused == 0
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "label-flip back to active reactivates a :deactivated entry" do
    test "human-review → in-progress on a :deactivated entry routes through reactivate_issue" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-relabel-active-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-relabel-1"
      issue_identifier = "RL-1"

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        # Start with a :deactivated entry (the post-U2 shape).
        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: nil,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "human-review", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :deactivated}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        # Label flips back to in-progress (e.g., operator requested rework).
        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "in-progress",
          title: "Rework requested",
          description: "",
          labels: []
        }

        updated_state = Reconciler.reconcile_running_issue_states([issue], state)

        # The entry's stored issue is refreshed to the new state.
        entry = Map.fetch!(updated_state.running, issue_id)
        assert entry.issue.state == "in-progress"

        # The entry is no longer :deactivated — reactivate_issue cleared
        # the status (may or may not have a pid yet depending on the
        # dispatcher's worker-host check, but it should NOT still be
        # `:deactivated`).
        refute get_in(entry, [:control, :status]) == :deactivated
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "PR review-comment firehose reactivation (subscriber wiring)" do
    test "topic parser extracts the issue number from a valid topic" do
      # Helper covers the regex shape used by the orchestrator's
      # handle_info({:event, ...}) clause. Anchors guard against
      # accidental match drift if other ticket subtopics are added.
      assert {:ok, "140"} =
               EventTopics.parse_pr_review_comment_topic("ticket.140.pr.review_comment")
    end

    test "topic parser rejects unrelated topics" do
      for unrelated <- [
            "ticket.140.issue.commented",
            "ticket.140.pr.opened",
            "ticket.140.agent.progress",
            "system.repo.branch.push"
          ] do
        assert :nomatch = EventTopics.parse_pr_review_comment_topic(unrelated)
      end
    end
  end

  describe "issue.commented firehose reactivation (subscriber wiring)" do
    test "topic parser extracts the ticket number from a valid topic" do
      assert {:ok, "7"} =
               EventTopics.parse_issue_commented_topic("ticket.7.issue.commented")
    end

    test "topic parser rejects unrelated topics" do
      for unrelated <- [
            "ticket.7.pr.review_comment",
            "ticket.7.issue.comment",
            "ticket.7.issue.commented.extra",
            "ticket.7.pr.opened",
            "system.repo.branch.push"
          ] do
        assert :nomatch = EventTopics.parse_issue_commented_topic(unrelated)
      end
    end

    test "reactivates a :deactivated entry on ticket.<N>.issue.commented when refreshed state is active" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-issue-commented-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-issue-commented-1"
      # The firehose resolves PR-conversation comments back to the ticket
      # id before publishing, so the topic number is the agent identifier.
      issue_identifier = "7"
      previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)
      previous_memory_recipient = Application.get_env(:aiur, :memory_tracker_recipient)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :memory_tracker_recipient, self())

        Application.put_env(:aiur, :memory_tracker_issues, [
          %Issue{
            id: issue_id,
            identifier: issue_identifier,
            state: "rework",
            title: "Rework requested",
            description: "",
            labels: []
          }
        ])

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: nil,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "human-review", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :deactivated}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        event = %{
          id: 7001,
          topic: "ticket.#{issue_identifier}.issue.commented",
          author_trusted?: true,
          comment: %{body: "Please fix the handoff."}
        }

        {:noreply, next} = Orchestrator.handle_info({:event, event}, state)

        assert_receive {:memory_tracker_state_update, ^issue_id, "rework"}

        entry = Map.fetch!(next.running, issue_id)
        assert entry.issue.state == "rework"
        refute get_in(entry, [:control, :status]) == :deactivated

        # The durable subscription path calls this queue boundary independently
        # of the orchestrator's rework transition. Once the deactivated entry
        # is restarted, its first turn can claim the same feedback digest.
        assert {:reply, :ok, delivered} =
                 Orchestrator.handle_call({:enqueue_event_digest, issue_identifier, event}, self(), next)

        assert [
                 %{
                   event_type: :events_digest,
                   body: %{events: [^event]}
                 }
               ] = AgentQueueStore.list_pending(delivered.queue_store, issue_identifier)
      after
        if previous_memory_issues do
          Application.put_env(:aiur, :memory_tracker_issues, previous_memory_issues)
        else
          Application.delete_env(:aiur, :memory_tracker_issues)
        end

        if previous_memory_recipient do
          Application.put_env(:aiur, :memory_tracker_recipient, previous_memory_recipient)
        else
          Application.delete_env(:aiur, :memory_tracker_recipient)
        end

        File.rm_rf(test_root)
      end
    end

    test "reactivates a :deactivated entry on ticket.<N>.pr.review_comment when refreshed state is active" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-pr-review-comment-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-pr-review-comment-1"
      issue_identifier = "44"
      previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)
      previous_memory_recipient = Application.get_env(:aiur, :memory_tracker_recipient)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :memory_tracker_recipient, self())

        Application.put_env(:aiur, :memory_tracker_issues, [
          %Issue{
            id: issue_id,
            identifier: issue_identifier,
            state: "rework",
            title: "Review comment requested rework",
            description: "",
            labels: []
          }
        ])

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: nil,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "human-review", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :deactivated}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        {:noreply, next} =
          Orchestrator.handle_info(
            {:event, %{topic: "ticket.#{issue_identifier}.pr.review_comment", author_trusted?: true}},
            state
          )

        assert_receive {:memory_tracker_state_update, ^issue_id, "rework"}

        entry = Map.fetch!(next.running, issue_id)
        assert entry.issue.state == "rework"
        refute get_in(entry, [:control, :status]) == :deactivated
      after
        if previous_memory_issues do
          Application.put_env(:aiur, :memory_tracker_issues, previous_memory_issues)
        else
          Application.delete_env(:aiur, :memory_tracker_issues)
        end

        if previous_memory_recipient do
          Application.put_env(:aiur, :memory_tracker_recipient, previous_memory_recipient)
        else
          Application.delete_env(:aiur, :memory_tracker_recipient)
        end

        File.rm_rf(test_root)
      end
    end

    test "persists an actionable alert when trusted issue feedback cannot claim a rework slot" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-issue-commented-capacity-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-issue-commented-capacity"
      issue_identifier = "45"
      workspace = Path.join(test_root, issue_identifier)
      previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)
      previous_memory_recipient = Application.get_env(:aiur, :memory_tracker_recipient)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"],
          worker_ssh_hosts: ["worker-1"],
          worker_max_concurrent_agents_per_host: 1
        )

        File.mkdir_p!(workspace)
        Application.put_env(:aiur, :memory_tracker_recipient, self())

        Application.put_env(:aiur, :memory_tracker_issues, [
          %Issue{
            id: issue_id,
            identifier: issue_identifier,
            state: "rework",
            title: "Review feedback pending",
            description: "",
            labels: []
          }
        ])

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: nil,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "human-review", identifier: issue_identifier},
              workspace_path: workspace,
              worker_host: "worker-1",
              started_at: DateTime.utc_now(),
              control: %{status: :deactivated}
            },
            "busy-issue" => %{
              pid: nil,
              ref: nil,
              identifier: "busy",
              issue: %Issue{id: "busy-issue", state: "in-progress", identifier: "busy"},
              worker_host: "worker-1",
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue_id, "busy-issue"]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 2
        }

        parent = self()

        log =
          capture_log(fn ->
            send(
              parent,
              Orchestrator.handle_info(
                {:event,
                 %{
                   topic: "ticket.#{issue_identifier}.issue.commented",
                   author_trusted?: true,
                   comment: %{body: "Please fix the lost workspace handoff."}
                 }},
                state
              )
            )
          end)

        assert_receive {:noreply, next}

        assert_receive {:memory_tracker_state_update, ^issue_id, "rework"}

        entry = Map.fetch!(next.running, issue_id)
        assert entry.issue.state == "rework"
        assert get_in(entry, [:control, :status]) == :deactivated
        assert log =~ "issue comment reactivation deferred"

        # Remote workers cannot write their workspace logs from the
        # orchestrator host, so the durable operator alert belongs in the
        # central feed instead.
        log =
          :aiur
          |> Application.fetch_env!(:log_file)
          |> Path.dirname()
          |> Path.join("alerts.ndjson")
          |> File.read!()

        assert log =~ "\"name\":\"ticket.#{issue_identifier}.agent.review_feedback_delivery_deferred\""
        assert log =~ "\"needs_attention\":true"
        assert log =~ "\"severity\":\"warning\""
      after
        if previous_memory_issues do
          Application.put_env(:aiur, :memory_tracker_issues, previous_memory_issues)
        else
          Application.delete_env(:aiur, :memory_tracker_issues)
        end

        if previous_memory_recipient do
          Application.put_env(:aiur, :memory_tracker_recipient, previous_memory_recipient)
        else
          Application.delete_env(:aiur, :memory_tracker_recipient)
        end

        File.rm_rf(test_root)
      end
    end

    test "does not reactivate a human-review entry on ticket.<N>.issue.commented" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-issue-commented-human-review-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-issue-commented-hr"
      issue_identifier = "43"
      previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        Application.put_env(:aiur, :memory_tracker_issues, [
          %Issue{
            id: issue_id,
            identifier: issue_identifier,
            state: "human-review",
            title: "Ready for human review",
            description: "",
            labels: []
          }
        ])

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: nil,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "human-review", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :deactivated}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        {:noreply, next} =
          Orchestrator.handle_info(
            {:event, %{topic: "ticket.#{issue_identifier}.issue.commented"}},
            state
          )

        entry = Map.fetch!(next.running, issue_id)
        assert get_in(entry, [:control, :status]) == :deactivated
        assert entry.pid == nil
      after
        if previous_memory_issues do
          Application.put_env(:aiur, :memory_tracker_issues, previous_memory_issues)
        else
          Application.delete_env(:aiur, :memory_tracker_issues)
        end

        File.rm_rf(test_root)
      end
    end

    test "review-pass PR comment stays human-review until successful merge marks issue done" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-review-pass-merge-#{System.unique_integer([:positive])}"
        )

      issue_id = "560"
      issue_identifier = "560"
      previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)
      previous_memory_recipient = Application.get_env(:aiur, :memory_tracker_recipient)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :memory_tracker_recipient, self())
        Application.put_env(:aiur, :memory_tracker_issues, [])

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: nil,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "human-review", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :deactivated}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        {:noreply, after_comment} =
          Orchestrator.handle_info(
            {:event,
             %{
               topic: "ticket.#{issue_identifier}.issue.commented",
               author_trusted?: true,
               comment: %{body: "[codex] Review passed for commit abc123"}
             }},
            state
          )

        refute_receive {:memory_tracker_state_update, ^issue_id, "rework"}, 100
        assert get_in(after_comment.running[issue_id], [:control, :status]) == :deactivated

        {:noreply, after_review_comment} =
          Orchestrator.handle_info(
            {:event,
             %{
               topic: "ticket.#{issue_identifier}.pr.review_comment",
               author_trusted?: true,
               comment: %{body: "[codex] Review passed for commit abc123"}
             }},
            after_comment
          )

        refute_receive {:memory_tracker_state_update, ^issue_id, "rework"}, 100
        assert get_in(after_review_comment.running[issue_id], [:control, :status]) == :deactivated

        {:noreply, after_merge} =
          Orchestrator.handle_info(
            {:event, %{topic: "ticket.#{issue_identifier}.pr.merged"}},
            after_review_comment
          )

        assert_receive {:memory_tracker_state_update, ^issue_id, "done"}
        refute Map.has_key?(after_merge.running, issue_id)
        refute MapSet.member?(after_merge.claimed, issue_id)
      after
        if previous_memory_issues do
          Application.put_env(:aiur, :memory_tracker_issues, previous_memory_issues)
        else
          Application.delete_env(:aiur, :memory_tracker_issues)
        end

        if previous_memory_recipient do
          Application.put_env(:aiur, :memory_tracker_recipient, previous_memory_recipient)
        else
          Application.delete_env(:aiur, :memory_tracker_recipient)
        end

        File.rm_rf(test_root)
      end
    end

    test "does not reactivate when refreshed issue is missing" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-issue-commented-missing-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-issue-commented-missing"
      issue_identifier = "45"
      previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :memory_tracker_issues, [])

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: nil,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "human-review", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :deactivated}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        parent = self()

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            send(
              parent,
              Orchestrator.handle_info(
                {:event, %{topic: "ticket.#{issue_identifier}.issue.commented", author_trusted?: true}},
                state
              )
            )
          end)

        assert_receive {:noreply, next}
        entry = Map.fetch!(next.running, issue_id)
        assert get_in(entry, [:control, :status]) == :deactivated
        assert entry.pid == nil
        assert log =~ "issue_id=#{issue_id} issue_identifier=#{issue_identifier}"
        assert log =~ "reason=:missing"
      after
        if previous_memory_issues do
          Application.put_env(:aiur, :memory_tracker_issues, previous_memory_issues)
        else
          Application.delete_env(:aiur, :memory_tracker_issues)
        end

        File.rm_rf(test_root)
      end
    end

    test "does not reactivate when tracker refresh fails" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-issue-commented-refresh-error-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-issue-commented-refresh-error"
      issue_identifier = "46"
      previous_linear_client = Application.get_env(:aiur, :linear_client_module)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "linear",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        Application.put_env(:aiur, :linear_client_module, ErrorLinearClient)
        File.mkdir_p!(test_root)

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: nil,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "human-review", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :deactivated}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        parent = self()

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            send(
              parent,
              Orchestrator.handle_info(
                {:event, %{topic: "ticket.#{issue_identifier}.issue.commented", author_trusted?: true}},
                state
              )
            )
          end)

        assert_receive {:noreply, next}
        entry = Map.fetch!(next.running, issue_id)
        assert get_in(entry, [:control, :status]) == :deactivated
        assert entry.pid == nil
        assert log =~ "issue_id=#{issue_id} issue_identifier=#{issue_identifier}"
        assert log =~ "reason=:tracker_down"
      after
        if previous_linear_client do
          Application.put_env(:aiur, :linear_client_module, previous_linear_client)
        else
          Application.delete_env(:aiur, :linear_client_module)
        end

        File.rm_rf(test_root)
      end
    end

    test "trusted comment for an idle issue queues the comment and schedules dispatch" do
      issue_id = "issue-issue-commented-2"
      issue_identifier = "7"
      previous_memory_recipient = Application.get_env(:aiur, :memory_tracker_recipient)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        Application.put_env(:aiur, :memory_tracker_recipient, self())

        state = %Orchestrator.State{
          running: %{},
          claimed: MapSet.new(),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        event = %{
          id: 123,
          topic: "ticket.#{issue_identifier}.issue.commented",
          source: :github,
          author_trusted?: true,
          message: "please fix the PR",
          comment: %{"body" => "please fix the PR"}
        }

        assert {:noreply, next_state} =
                 Orchestrator.handle_info(
                   {:event, event},
                   state
                 )

        assert_receive {:memory_tracker_state_update, ^issue_identifier, "rework"}
        refute_receive {:memory_tracker_state_update, ^issue_id, "rework"}, 50

        assert [
                 %{
                   event_type: :events_digest,
                   body: %{events: [^event]}
                 }
               ] = AgentQueueStore.list_pending(next_state.queue_store, issue_identifier)

        assert %{
                 subscribed_to: subscribed_to
               } = SubscriptionStore.snapshot(issue_identifier)

        topics = Enum.map(subscribed_to, & &1["topic"])
        assert "ticket.#{issue_identifier}.issue.commented" in topics
        assert "ticket.#{issue_identifier}.pr.review_comment" in topics
        assert_receive :run_poll_cycle, 100
      after
        :ok = SubscriptionStore.stop(issue_identifier)

        if previous_memory_recipient do
          Application.put_env(:aiur, :memory_tracker_recipient, previous_memory_recipient)
        else
          Application.delete_env(:aiur, :memory_tracker_recipient)
        end
      end
    end

    test "trusted idle review comment preserves stale active state while recording resume intent" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-direct-comment-dispatch-#{System.unique_integer([:positive])}"
        )

      issue_identifier = "58"
      fake_codex = Path.join(test_root, "fake-codex")
      previous_github_client = Application.get_env(:aiur, :github_client_module)
      previous_direct_recipient = Application.get_env(:aiur, :direct_dispatch_recipient)
      previous_direct_issues = Application.get_env(:aiur, :direct_dispatch_issues)

      previous_lifecycle_recorder =
        Application.get_env(:aiur, :run_telemetry_lifecycle_recorder)

      test_pid = self()

      Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, fn kind, attributes, opts ->
        send(test_pid, {:lifecycle, kind, attributes, opts})
        :ok
      end)

      try do
        File.mkdir_p!(test_root)
        File.write!(fake_codex, "#!/bin/sh\nsleep 30\n")
        File.chmod!(fake_codex, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "github",
          workspace_root: test_root,
          tracker_repo: "owner/repo",
          tracker_label_prefix: "agent",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"],
          codex_command: "#{fake_codex} app-server"
        )

        Application.put_env(:aiur, :github_client_module, DirectDispatchGitHubClient)
        Application.put_env(:aiur, :direct_dispatch_recipient, self())

        Application.put_env(:aiur, :direct_dispatch_issues, [
          %Issue{
            id: issue_identifier,
            identifier: issue_identifier,
            state: "todo",
            title: "Review comment requested rework",
            description: "",
            labels: []
          }
        ])

        state = %Orchestrator.State{
          running: %{},
          claimed: MapSet.new(),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        event = %{
          id: 3_473_822_447,
          topic: "ticket.#{issue_identifier}.pr.review_comment",
          source: :github,
          author_trusted?: true,
          message: "please acknowledge this inline review comment",
          comment: %{
            "body" => "please acknowledge this inline review comment",
            "id" => 3_473_822_447
          }
        }

        assert {:noreply, next_state} = Orchestrator.handle_info({:event, event}, state)

        assert_receive {:direct_dispatch_update, ^issue_identifier, "rework"}
        assert_receive {:direct_dispatch_fetch, [^issue_identifier]}
        refute_received :run_poll_cycle

        assert [
                 %{
                   event_type: :events_digest,
                   body: %{events: [^event]}
                 }
               ] = AgentQueueStore.list_pending(next_state.queue_store, issue_identifier)

        assert %{^issue_identifier => entry} = next_state.running
        assert entry.issue.state == "todo"
        assert MapSet.member?(next_state.claimed, issue_identifier)

        assert_receive {:lifecycle, :lifecycle,
                        %{
                          event: "agent_resume",
                          cause: "rework_dispatch",
                          attempt_id: attempt_id
                        }, []},
                       2_000

        assert is_binary(attempt_id)

        if is_pid(entry.pid) and Process.alive?(entry.pid) do
          Process.exit(entry.pid, :kill)

          receive do
            {:DOWN, _ref, :process, pid, _reason} when pid == entry.pid -> :ok
          after
            100 -> :ok
          end
        end
      after
        restore_application_env(:github_client_module, previous_github_client)
        restore_application_env(:direct_dispatch_recipient, previous_direct_recipient)
        restore_application_env(:direct_dispatch_issues, previous_direct_issues)
        restore_application_env(:run_telemetry_lifecycle_recorder, previous_lifecycle_recorder)
        File.rm_rf(test_root)
      end
    end

    test "trusted idle review comment does not admit a concurrently terminal issue" do
      issue_identifier = "58"
      previous_github_client = Application.get_env(:aiur, :github_client_module)
      previous_direct_recipient = Application.get_env(:aiur, :direct_dispatch_recipient)
      previous_direct_issues = Application.get_env(:aiur, :direct_dispatch_issues)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "github",
          tracker_repo: "owner/repo",
          tracker_label_prefix: "agent",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        Application.put_env(:aiur, :github_client_module, DirectDispatchGitHubClient)
        Application.put_env(:aiur, :direct_dispatch_recipient, self())

        Application.put_env(:aiur, :direct_dispatch_issues, [
          %Issue{
            id: issue_identifier,
            identifier: issue_identifier,
            state: "done",
            title: "Merged while the comment event was in flight",
            description: "",
            labels: []
          }
        ])

        state = %Orchestrator.State{
          running: %{},
          claimed: MapSet.new(),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        event = %{
          id: 3_473_822_448,
          topic: "ticket.#{issue_identifier}.pr.review_comment",
          source: :github,
          author_trusted?: true,
          message: "comment raced with merge",
          comment: %{"body" => "comment raced with merge", "id" => 3_473_822_448}
        }

        assert {:noreply, next_state} = Orchestrator.handle_info({:event, event}, state)

        assert_receive {:direct_dispatch_update, ^issue_identifier, "rework"}
        assert_receive {:direct_dispatch_fetch, [^issue_identifier]}
        refute_receive {:direct_dispatch_fetch, [^issue_identifier]}, 100
        assert_receive :run_poll_cycle, 100
        assert next_state.running == %{}
        assert next_state.claimed == MapSet.new()
      after
        restore_application_env(:github_client_module, previous_github_client)
        restore_application_env(:direct_dispatch_recipient, previous_direct_recipient)
        restore_application_env(:direct_dispatch_issues, previous_direct_issues)
      end
    end

    test "trusted idle review comment retries a transient rework transition failure" do
      issue_identifier = "58"
      previous_github_client = Application.get_env(:aiur, :github_client_module)
      previous_recipient = Application.get_env(:aiur, :flaky_rework_recipient)
      previous_agent = Application.get_env(:aiur, :flaky_rework_agent)
      previous_owner = Application.get_env(:aiur, :flaky_rework_owner)
      previous_delay = Application.get_env(:aiur, :comment_rework_retry_delay_ms)
      previous_max = Application.get_env(:aiur, :comment_rework_max_attempts)
      {:ok, agent} = Agent.start_link(fn -> [{:error, {:github_api_status, 502}}, :ok] end)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "github",
          tracker_repo: "owner/repo",
          tracker_label_prefix: "agent",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        Application.put_env(:aiur, :flaky_rework_recipient, self())
        Application.put_env(:aiur, :flaky_rework_agent, agent)
        Application.put_env(:aiur, :flaky_rework_owner, self())
        Application.put_env(:aiur, :github_client_module, FlakyReworkGitHubClient)
        Application.put_env(:aiur, :comment_rework_retry_delay_ms, 1)
        Application.put_env(:aiur, :comment_rework_max_attempts, 3)

        assert {:error, :unexpected_test_caller} =
                 Task.async(fn ->
                   FlakyReworkGitHubClient.update_issue_state("unrelated", "rework")
                 end)
                 |> Task.await()

        state = %Orchestrator.State{
          running: %{},
          claimed: MapSet.new(),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        event = %{
          id: 3_473_356_579,
          topic: "ticket.#{issue_identifier}.pr.review_comment",
          source: :github,
          author_trusted?: true,
          message: "please acknowledge this inline review comment",
          comment: %{
            "body" => "please acknowledge this inline review comment",
            "id" => 3_473_356_579
          }
        }

        assert {:noreply, failed_state} = Orchestrator.handle_info({:event, event}, state)

        assert_receive {:flaky_rework_update, ^issue_identifier, "rework"}
        assert [] = AgentQueueStore.list_pending(failed_state.queue_store, issue_identifier)

        assert_receive {:retry_comment_rework, ^issue_identifier, "PR review comment", ^event, 2},
                       100

        assert {:noreply, retry_state} =
                 Orchestrator.handle_info(
                   {:retry_comment_rework, issue_identifier, "PR review comment", event, 2},
                   failed_state
                 )

        assert_receive {:flaky_rework_update, ^issue_identifier, "rework"}

        assert [
                 %{
                   event_type: :events_digest,
                   body: %{events: [^event]}
                 }
               ] = AgentQueueStore.list_pending(retry_state.queue_store, issue_identifier)

        assert %{
                 subscribed_to: subscribed_to
               } = SubscriptionStore.snapshot(issue_identifier)

        topics = Enum.map(subscribed_to, & &1["topic"])
        assert "ticket.#{issue_identifier}.issue.commented" in topics
        assert "ticket.#{issue_identifier}.pr.review_comment" in topics
        assert_receive :run_poll_cycle, 100
      after
        :ok = SubscriptionStore.stop(issue_identifier)

        restore_application_env(:github_client_module, previous_github_client)
        restore_application_env(:flaky_rework_recipient, previous_recipient)
        restore_application_env(:flaky_rework_agent, previous_agent)
        restore_application_env(:flaky_rework_owner, previous_owner)
        restore_application_env(:comment_rework_retry_delay_ms, previous_delay)
        restore_application_env(:comment_rework_max_attempts, previous_max)

        if Process.alive?(agent), do: Agent.stop(agent)
      end
    end

    test "direct comment poll watches human-review issues without running entries" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      issue = %Issue{id: "57", identifier: "57", state: "human-review"}
      :ok = Exchange.subscribe("ticket.57.pr.review_comment")

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/57/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls?") ->
            {:ok, %{status: 200, body: [%{"number" => 61}]}}

          String.contains?(url, "/issues/61/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls/61/reviews") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/graphql") ->
            review_threads_response([
              %{
                "id" => "PRRT_human_review_only",
                "isResolved" => false,
                "path" => "lib/app.ex",
                "line" => 12,
                "comments" => %{
                  "nodes" => [
                    review_thread_comment(5701, "its-everdred", "same-whale transfers should stay sequential")
                  ]
                }
              }
            ])
        end
      end

      state = %Orchestrator.State{
        running: %{},
        github_comments_since: "2026-06-24T11:00:00Z"
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging"] -> {:ok, [issue]} end
        )

      assert next.github_comments_since == %{"57" => "2026-06-24T11:00:00Z"}

      assert_receive {:event,
                      %{
                        topic: "ticket.57.pr.review_comment",
                        source: :github,
                        message: "same-whale transfers should stay sequential"
                      }},
                     500
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "direct comment poll watches merging issues without running entries (#696)" do
      # The comment listener must cover merging tickets too, not only
      # human-review, so a reviewer's last-minute comment during merge is seen
      # and can promote the ticket to rework — independent of `active_states`.
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      issue = %Issue{id: "63", identifier: "63", state: "merging"}
      :ok = Exchange.subscribe("ticket.63.issue.commented")

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/63/comments?") ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "id" => 6301,
                   "body" => "hold the merge — please revert the rename",
                   "updated_at" => "2026-06-24T12:00:00Z",
                   "user" => %{"login" => "its-everdred"}
                 }
               ]
             }}

          String.contains?(url, "/pulls?") ->
            {:ok, %{status: 200, body: []}}
        end
      end

      state = %Orchestrator.State{
        running: %{},
        github_comments_since: "2026-06-24T11:00:00Z"
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging"] -> {:ok, [issue]} end
        )

      assert next.github_comments_since == %{"63" => "2026-06-24T11:59:59Z"}

      assert_receive {:event,
                      %{
                        topic: "ticket.63.issue.commented",
                        source: :github,
                        message: "hold the merge — please revert the rename"
                      }},
                     500
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "direct comment poll keeps running and human-review targets" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      human_review_issue = %Issue{id: "57", identifier: "57", state: "human-review"}
      :ok = Exchange.subscribe("ticket.42.issue.commented")
      :ok = Exchange.subscribe("ticket.57.pr.review_comment")

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/42/comments?") ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "id" => 4201,
                   "body" => "running target comment",
                   "updated_at" => "2026-06-24T12:00:00Z",
                   "user" => %{"login" => "its-everdred"}
                 }
               ]
             }}

          String.contains?(url, "/issues/57/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls?") and String.contains?(url, "aiur%2F57") ->
            {:ok, %{status: 200, body: [%{"number" => 61}]}}

          String.contains?(url, "/pulls?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/issues/61/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls/61/reviews") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/graphql") ->
            review_threads_response([
              %{
                "id" => "PRRT_human_review_with_running",
                "isResolved" => false,
                "path" => "lib/app.ex",
                "line" => 12,
                "comments" => %{
                  "nodes" => [
                    review_thread_comment(5702, "its-everdred", "human-review target comment")
                  ]
                }
              }
            ])
        end
      end

      state = %Orchestrator.State{
        running: %{
          "issue-42" => %{
            identifier: "42",
            issue: %Issue{id: "issue-42", state: "in-progress", identifier: "42"},
            control: %{status: :working}
          }
        },
        github_comments_since: "2026-06-24T11:00:00Z"
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging"] -> {:ok, [human_review_issue]} end
        )

      assert next.github_comments_since == %{
               "42" => "2026-06-24T11:59:59Z",
               "57" => "2026-06-24T11:00:00Z"
             }

      assert_receive {:event, %{topic: "ticket.42.issue.commented", message: "running target comment"}}, 500

      assert_receive {:event, %{topic: "ticket.57.pr.review_comment", message: "human-review target comment"}},
                     500
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "direct comment poll bounds human-review targets by oldest cursor" do
      parent = self()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      issues =
        for id <- ~w(10 11 12 13) do
          %Issue{
            id: id,
            identifier: id,
            state: "human-review",
            updated_at: datetime!("2026-06-24T12:00:00Z")
          }
        end

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/") and String.contains?(url, "/comments?") ->
            [_, id] = Regex.run(~r{/issues/([^/]+)/comments\?}, url)
            send(parent, {:issue_comments_requested, id})
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls?") ->
            send(parent, {:pulls_requested, url})
            {:ok, %{status: 200, body: []}}
        end
      end

      state = %Orchestrator.State{
        running: %{},
        github_comments_since: %{
          "10" => "2026-06-24T12:00:00Z",
          "11" => "2026-06-24T10:00:00Z",
          "12" => "2026-06-24T11:00:00Z",
          "13" => "2026-06-24T09:00:00Z"
        }
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging"] -> {:ok, issues} end,
          human_review_comment_target_limit: 2,
          max_concurrency: 1
        )

      assert_receive {:issue_comments_requested, "13"}, 500
      assert_receive {:issue_comments_requested, "11"}, 500
      refute_receive {:issue_comments_requested, _}, 100
      assert_receive {:pulls_requested, pulls_13}, 500
      assert_receive {:pulls_requested, readable_pulls_13}, 500
      assert_receive {:pulls_requested, pulls_11}, 500
      assert_receive {:pulls_requested, readable_pulls_11}, 500
      refute_receive {:pulls_requested, _}, 100

      assert String.contains?(pulls_13, "aiur%2F13")
      assert String.contains?(pulls_11, "aiur%2F11")
      refute String.contains?(readable_pulls_13, "head=")
      refute String.contains?(readable_pulls_11, "head=")

      assert next.github_comments_since == %{
               "10" => "2026-06-24T12:00:00Z",
               "11" => "2026-06-24T10:00:00Z",
               "12" => "2026-06-24T11:00:00Z",
               "13" => "2026-06-24T09:00:00Z"
             }

      assert next.github_comment_issue_updated_at == %{
               "11" => "2026-06-24T12:00:00Z",
               "13" => "2026-06-24T12:00:00Z"
             }
    end

    test "direct comment poll skips unchanged human-review issues" do
      parent = self()
      updated_at = "2026-06-24T12:00:00Z"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      issue = %Issue{
        id: "57",
        identifier: "57",
        state: "human-review",
        updated_at: datetime!(updated_at)
      }

      request_fun = fn %{url: url} ->
        if String.contains?(url, "/pulls?") do
          {:ok, %{status: 200, body: []}}
        else
          send(parent, {:unexpected_comment_request, url})
          {:ok, %{status: 200, body: []}}
        end
      end

      state = %Orchestrator.State{
        running: %{},
        github_comments_since: %{"57" => "2026-06-24T11:59:59Z"},
        github_comment_issue_updated_at: %{"57" => updated_at}
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging"] -> {:ok, [issue]} end
        )

      assert next.github_comments_since == %{"57" => "2026-06-24T11:59:59Z"}
      assert next.github_comment_issue_updated_at == %{"57" => updated_at}
      refute_receive {:unexpected_comment_request, _url}, 100
    end

    test "direct comment poll checks unchanged human-review issue when open PR changed" do
      parent = self()
      issue_updated_at = "2026-06-24T12:00:00Z"
      pr_updated_at = "2026-06-24T12:03:00Z"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      issue = %Issue{
        id: "57",
        identifier: "57",
        state: "human-review",
        updated_at: datetime!(issue_updated_at)
      }

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/57/comments?") ->
            send(parent, :issue_comments_requested)
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls?") ->
            send(parent, {:unexpected_pull_request_lookup, url})
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/issues/61/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls/61/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls/61/reviews") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/graphql") ->
            empty_review_threads_response()
        end
      end

      state = %Orchestrator.State{
        running: %{},
        github_comments_since: %{"57" => "2026-06-24T11:59:59Z"},
        github_comment_issue_updated_at: %{"57" => issue_updated_at}
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging"] -> {:ok, [issue]} end,
          review_pull_request_fetcher: fn "57" -> {:ok, %{"number" => 61, "updated_at" => pr_updated_at}} end
        )

      assert_receive :issue_comments_requested, 500
      refute_receive {:unexpected_pull_request_lookup, _url}, 100

      assert next.github_comment_issue_updated_at == %{
               "57" => "issue=#{issue_updated_at};pr=#{pr_updated_at}"
             }
    end

    test "direct comment poll prefers unknown human-review targets before capped PR lookups" do
      parent = self()
      updated_at = "2026-06-24T12:00:00Z"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      issues =
        for id <- ~w(10 11) do
          %Issue{
            id: id,
            identifier: id,
            state: "human-review",
            updated_at: datetime!(updated_at)
          }
        end

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/11/comments?") ->
            send(parent, {:issue_comments_requested, "11"})
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls?") ->
            send(parent, {:pulls_requested, url})
            {:ok, %{status: 200, body: []}}
        end
      end

      state = %Orchestrator.State{
        running: %{},
        github_comments_since: %{
          "10" => "2026-06-24T09:00:00Z",
          "11" => "2026-06-24T10:00:00Z"
        },
        github_comment_issue_updated_at: %{"10" => updated_at}
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging"] -> {:ok, issues} end,
          human_review_comment_target_limit: 1,
          max_concurrency: 1
        )

      assert_receive {:pulls_requested, pulls_11}, 500
      assert_receive {:pulls_requested, readable_pulls_11}, 500
      assert_receive {:issue_comments_requested, "11"}, 500
      refute_receive {:pulls_requested, _}, 100
      refute_receive {:issue_comments_requested, _}, 100

      assert String.contains?(pulls_11, "aiur%2F11")
      refute String.contains?(readable_pulls_11, "head=")

      assert next.github_comment_issue_updated_at == %{
               "10" => updated_at,
               "11" => updated_at
             }
    end

    test "human-review target failure does not stop running target cursor advancement" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      human_review_issue = %Issue{
        id: "57",
        identifier: "57",
        state: "human-review",
        updated_at: datetime!("2026-06-24T12:00:00Z")
      }

      :ok = Exchange.subscribe("ticket.42.issue.commented")

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/42/comments?") ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "id" => 4203,
                   "body" => "running target still advances",
                   "updated_at" => "2026-06-24T12:03:00Z",
                   "user" => %{"login" => "its-everdred"}
                 }
               ]
             }}

          String.contains?(url, "/issues/57/comments?") ->
            {:error, :timeout}

          String.contains?(url, "/pulls?") ->
            {:ok, %{status: 200, body: []}}
        end
      end

      state = %Orchestrator.State{
        running: %{
          "issue-42" => %{
            identifier: "42",
            issue: %Issue{id: "issue-42", state: "in-progress", identifier: "42"},
            control: %{status: :working}
          }
        },
        github_comments_since: %{
          "42" => "2026-06-24T11:00:00Z",
          "57" => "2026-06-24T11:00:00Z"
        }
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging"] -> {:ok, [human_review_issue]} end,
          max_concurrency: 1
        )

      assert next.github_comments_since == %{
               "42" => "2026-06-24T12:02:59Z",
               "57" => "2026-06-24T11:00:00Z"
             }

      assert next.github_comment_issue_updated_at == %{}
      assert next.github_poll_delays == %{}
      assert_receive {:event, %{topic: "ticket.42.issue.commented", message: "running target still advances"}}, 500
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "direct comment poll preserves cursor when human-review target refresh fails" do
      parent = self()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      :ok = Exchange.subscribe("ticket.42.issue.commented")

      request_fun = fn %{url: url} ->
        send(parent, {:unexpected_comment_request, url})

        {:ok,
         %{
           status: 200,
           body: [
             %{
               "id" => 4201,
               "body" => "running target comment",
               "updated_at" => "2026-06-24T12:00:00Z",
               "user" => %{"login" => "its-everdred"}
             }
           ]
         }}
      end

      state = %Orchestrator.State{
        running: %{
          "issue-42" => %{
            identifier: "42",
            issue: %Issue{id: "issue-42", state: "in-progress", identifier: "42"},
            control: %{status: :working}
          }
        },
        github_comments_since: "2026-06-24T11:00:00Z"
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging"] -> {:error, :tracker_down} end
        )

      assert next.github_comments_since == "2026-06-24T11:00:00Z"
      refute_receive {:unexpected_comment_request, _url}, 100
      refute_receive {:event, _event}, 100
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "keeps the active runner while fencing a trusted comment as rework" do
      issue_id = "issue-issue-commented-3"
      issue_identifier = "7"
      previous_memory_recipient = Application.get_env(:aiur, :memory_tracker_recipient)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        Application.put_env(:aiur, :memory_tracker_recipient, self())

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: nil,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "in-progress", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        event = %{
          id: 70_003,
          topic: "ticket.#{issue_identifier}.issue.commented",
          author_trusted?: true,
          comment: %{body: "Please rework this head"}
        }

        assert {:noreply, next} =
                 Orchestrator.handle_info(
                   {:event, event},
                   state
                 )

        # The active runner remains the sole workspace writer, while the
        # concrete queued comment opens a rework fence until provider receipt.
        assert map_size(next.running) == 1
        assert next.running[issue_id].pid == nil
        assert next.running[issue_id].ref == nil
        assert next.running[issue_id].control.status == :working
        assert next.running[issue_id].issue.state == "rework"

        assert %{pending_item_ids: pending_ids, authoritative_state: "rework"} =
                 next.running[issue_id].lifecycle_fence

        assert MapSet.size(pending_ids) == 1
        [item_id] = MapSet.to_list(pending_ids)
        item = AgentQueueStore.get(next.queue_store, item_id)
        assert item.status == :pending
        assert item.delivery.priority == :now
        assert item.delivery.interrupt_requested == true
        assert item.body.events == [event]
        assert_receive {:memory_tracker_state_update, ^issue_id, "rework"}
      after
        if previous_memory_recipient do
          Application.put_env(:aiur, :memory_tracker_recipient, previous_memory_recipient)
        else
          Application.delete_env(:aiur, :memory_tracker_recipient)
        end
      end
    end
  end

  describe "idle review comment auto-promote to rework (no running entry) (#696)" do
    # The live #696 symptom was an `agent:human-review` ticket with no running
    # agent whose trusted reviewer comment was logged as
    # "issue comment ignored for idle issue". These drive the idle path —
    # `handle_info({:event, ...})` with an empty `running` map →
    # `maybe_transition_idle_issue_to_rework` — across the three acceptance
    # scenarios: trusted promotes to rework; untrusted and the bot's own
    # comment do not (no self-trigger loop).
    setup do
      previous_recipient = Application.get_env(:aiur, :memory_tracker_recipient)
      previous_issues = Application.get_env(:aiur, :memory_tracker_issues)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      Application.put_env(:aiur, :memory_tracker_recipient, self())

      on_exit(fn ->
        restore_application_env(:memory_tracker_recipient, previous_recipient)
        restore_application_env(:memory_tracker_issues, previous_issues)
      end)

      :ok
    end

    test "a trusted comment on a human-review ticket transitions it to rework" do
      issue_identifier = "70"

      Application.put_env(:aiur, :memory_tracker_issues, [
        %Issue{
          id: issue_identifier,
          identifier: issue_identifier,
          state: "human-review",
          title: "PR up for review",
          description: "",
          labels: []
        }
      ])

      {:noreply, _next} =
        Orchestrator.handle_info(
          {:event,
           %{
             topic: "ticket.#{issue_identifier}.issue.commented",
             author_trusted?: true,
             comment: %{body: "Please rename the helper to decode_frame/1"}
           }},
          empty_orchestrator_state()
        )

      assert_receive {:memory_tracker_state_update, ^issue_identifier, "rework"}
    end

    test "a trusted comment on a merging ticket transitions it to rework" do
      # #696's merging extension: a last-minute "actually, change this" comment
      # during merge must promote the idle ticket too, not only human-review.
      issue_identifier = "73"

      Application.put_env(:aiur, :memory_tracker_issues, [
        %Issue{
          id: issue_identifier,
          identifier: issue_identifier,
          state: "merging",
          title: "PR mid-merge",
          description: "",
          labels: []
        }
      ])

      {:noreply, _next} =
        Orchestrator.handle_info(
          {:event,
           %{
             topic: "ticket.#{issue_identifier}.issue.commented",
             author_trusted?: true,
             comment: %{body: "hold the merge — please revert the rename"}
           }},
          empty_orchestrator_state()
        )

      assert_receive {:memory_tracker_state_update, ^issue_identifier, "rework"}
    end

    test "an untrusted comment is ignored (no transition)" do
      issue_identifier = "71"

      Application.put_env(:aiur, :memory_tracker_issues, [
        %Issue{id: issue_identifier, identifier: issue_identifier, state: "human-review"}
      ])

      log =
        capture_log(fn ->
          {:noreply, _next} =
            Orchestrator.handle_info(
              {:event,
               %{
                 topic: "ticket.#{issue_identifier}.issue.commented",
                 author_trusted?: false,
                 comment: %{body: "drive-by comment from a stranger"}
               }},
              empty_orchestrator_state()
            )
        end)

      # Scope the refute to the issue under test (matching the positive cases'
      # `^issue_identifier`): a stray `rework` transition for an unrelated issue
      # leaked from another test in the suite must not be read as this idle
      # untrusted comment self-triggering a promotion (#708 CI flake).
      refute_receive {:memory_tracker_state_update, ^issue_identifier, "rework"}, 100
      assert log =~ "issue comment ignored for idle issue"
      assert log =~ ":untrusted_author"
    end

    test "the bot's own '[codex] review passed' comment does not self-trigger rework" do
      issue_identifier = "72"

      Application.put_env(:aiur, :memory_tracker_issues, [
        %Issue{id: issue_identifier, identifier: issue_identifier, state: "human-review"}
      ])

      log =
        capture_log(fn ->
          {:noreply, _next} =
            Orchestrator.handle_info(
              {:event,
               %{
                 topic: "ticket.#{issue_identifier}.issue.commented",
                 author_trusted?: true,
                 comment: %{body: "[codex] Review passed for commit abc123"}
               }},
              empty_orchestrator_state()
            )
        end)

      # Scope to the issue under test so a stray `rework` for an unrelated issue
      # (leaked from another suite test) can't masquerade as a self-trigger.
      refute_receive {:memory_tracker_state_update, ^issue_identifier, "rework"}, 100
      assert log =~ ":benign_review_pass_comment"
    end

    test "a trusted CHANGES_REQUESTED review wakes a fully-idle human-review ticket into rework" do
      # Regression coverage for #1389: a CHANGES_REQUESTED review posted while the
      # agent entry is fully torn down (no running entry) must still transition to
      # rework. This is the exact shape of the four reproductions from BO #1363.
      issue_identifier = "76"

      Application.put_env(:aiur, :memory_tracker_issues, [
        %Issue{
          id: issue_identifier,
          identifier: issue_identifier,
          state: "human-review",
          title: "PR awaiting review",
          description: "",
          labels: []
        }
      ])

      {:noreply, _next} =
        Orchestrator.handle_info(
          {:event,
           %{
             topic: "ticket.#{issue_identifier}.pr.review_comment",
             author_trusted?: true,
             comment: %{
               "state" => "CHANGES_REQUESTED",
               "body" => "Please rename the helper before merge",
               "user" => %{"login" => "its-everdred"},
               "submitted_at" => "2026-07-30T16:24:00Z"
             }
           }},
          empty_orchestrator_state()
        )

      assert_receive {:memory_tracker_state_update, ^issue_identifier, "rework"}
    end

    test "a trusted CHANGES_REQUESTED review wakes a :deactivated human-review entry into rework" do
      # Regression coverage for #1389: a review comment must also reactivate an
      # entry still present in state.running but marked :deactivated (human-review
      # paused). This path goes through reactivate_if_deactivated.
      issue_identifier = "77"
      issue_id = "issue-#{issue_identifier}"

      Application.put_env(:aiur, :memory_tracker_issues, [
        %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "rework",
          title: "PR changes requested",
          description: "",
          labels: []
        }
      ])

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "human-review", identifier: issue_identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :deactivated}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      {:noreply, next} =
        Orchestrator.handle_info(
          {:event,
           %{
             topic: "ticket.#{issue_identifier}.pr.review_comment",
             author_trusted?: true,
             comment: %{
               "state" => "CHANGES_REQUESTED",
               "body" => "Please rename the helper before merge",
               "user" => %{"login" => "its-everdred"},
               "submitted_at" => "2026-07-30T16:24:00Z"
             }
           }},
          state
        )

      assert_receive {:memory_tracker_state_update, ^issue_id, "rework"}
      entry = Map.fetch!(next.running, issue_id)
      refute get_in(entry, [:control, :status]) == :deactivated
    end
  end

  describe "watch-target discovery (agent:watch PR comment polling)" do
    test "open agent:watch PR becomes a pr#-keyed target and publishes ticket.<pr#>.pr.review_comment" do
      parent = self()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        pr_watch_enabled: true
      )

      :ok = Exchange.subscribe("ticket.314.pr.review_comment")

      watch_pr = %{
        "number" => 314,
        "state" => "open",
        "head" => %{"ref" => "feature/human-branch"},
        "labels" => [%{"name" => "agent:watch"}]
      }

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/314/comments?") ->
            {:ok, %{status: 200, body: []}}

          # The PR object is passed through; the poller must NOT branch-derive.
          String.contains?(url, "/pulls?") ->
            send(parent, {:unexpected_pull_request_lookup, url})
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/graphql") ->
            review_threads_response([
              %{
                "id" => "PRRT_watch_314",
                "isResolved" => false,
                "path" => "lib/app.ex",
                "line" => 7,
                "comments" => %{
                  "nodes" => [
                    review_thread_comment(31_401, "its-everdred", "watched PR feedback")
                  ]
                }
              }
            ])
        end
      end

      state = %Orchestrator.State{
        running: %{},
        github_comments_since: "2026-06-25T00:00:00Z"
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging"] -> {:ok, []} end,
          watch_pull_request_fetcher: fn "agent:watch" -> {:ok, [watch_pr]} end
        )

      assert next.github_comments_since == %{"314" => "2026-06-25T00:00:00Z"}

      assert_receive {:event,
                      %{
                        topic: "ticket.314.pr.review_comment",
                        source: :github,
                        message: "watched PR feedback"
                      }},
                     500

      refute_receive {:unexpected_pull_request_lookup, _url}, 100
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "watch targets are isolated: one failing PR does not stall or rewind the others" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        pr_watch_enabled: true
      )

      healthy_pr = %{"number" => 100, "state" => "open", "head" => %{"ref" => "branch-a"}}
      flaky_pr = %{"number" => 200, "state" => "open", "head" => %{"ref" => "branch-b"}}

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/100/comments?") ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "id" => 10_001,
                   "body" => "healthy watch comment",
                   "updated_at" => "2026-06-25T01:00:00Z",
                   "user" => %{"login" => "its-everdred"}
                 }
               ]
             }}

          # The flaky PR's issue/conversation fetch errors, so its cursor must
          # not advance — but it must not block the healthy PR either.
          String.contains?(url, "/issues/200/comments?") ->
            {:ok, %{status: 500, body: %{"message" => "boom"}}}

          String.contains?(url, "/graphql") ->
            empty_review_threads_response()
        end
      end

      state = %Orchestrator.State{
        running: %{},
        github_comments_since: %{
          "100" => "2026-06-25T00:00:00Z",
          "200" => "2026-06-25T00:00:00Z"
        }
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          max_concurrency: 1,
          review_issue_fetcher: fn ["human-review", "merging"] -> {:ok, []} end,
          watch_pull_request_fetcher: fn "agent:watch" -> {:ok, [healthy_pr, flaky_pr]} end
        )

      # Healthy target advanced (−1s rewind); flaky target held its cursor.
      assert next.github_comments_since == %{
               "100" => "2026-06-25T00:59:59Z",
               "200" => "2026-06-25T00:00:00Z"
             }
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "closed/merged watch PRs are excluded and the target set is capped (drop logged)" do
      parent = self()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        pr_watch_enabled: true
      )

      open_prs =
        for n <- 1..3 do
          %{"number" => n, "state" => "open", "head" => %{"ref" => "branch-#{n}"}}
        end

      merged_pr = %{
        "number" => 900,
        "state" => "closed",
        "merged_at" => "2026-06-25T00:00:00Z",
        "head" => %{"ref" => "merged-branch"}
      }

      closed_pr = %{"number" => 901, "state" => "closed", "head" => %{"ref" => "closed-branch"}}

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/") and String.contains?(url, "/comments?") ->
            [_, id] = Regex.run(~r{/issues/([^/]+)/comments\?}, url)
            send(parent, {:issue_comments_requested, id})
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/graphql") ->
            empty_review_threads_response()
        end
      end

      state = %Orchestrator.State{running: %{}, github_comments_since: %{}}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          CommentPolling.poll_github_comments(state,
            repo: "owner/repo",
            request_fun: request_fun,
            max_concurrency: 1,
            watch_comment_target_limit: 2,
            review_issue_fetcher: fn ["human-review", "merging"] -> {:ok, []} end,
            watch_pull_request_fetcher: fn "agent:watch" ->
              {:ok, open_prs ++ [merged_pr, closed_pr]}
            end
          )
        end)

      # Merged/closed PRs never become targets, and the open set is capped at 2.
      # A watched PR's target IS its PR number, so the poller hits
      # /issues/<pr#>/comments for both the issue and PR-conversation passes —
      # dedup to the distinct PR numbers actually polled.
      polled = drain_issue_comment_requests([]) |> Enum.uniq()

      assert length(polled) == 2
      assert Enum.all?(polled, &(&1 in ["1", "2", "3"]))
      refute "900" in polled
      refute "901" in polled
      assert log =~ "watch_comment_poll_targets capped"
      assert log =~ "dropped=1"
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "no watch targets are produced when pr_watch is disabled (default)" do
      parent = self()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      request_fun = fn %{url: url} ->
        send(parent, {:unexpected_request, url})
        {:ok, %{status: 200, body: []}}
      end

      state = %Orchestrator.State{running: %{}, github_comments_since: %{}}

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging"] -> {:ok, []} end,
          watch_pull_request_fetcher: fn _label ->
            send(parent, :unexpected_watch_fetch)
            {:ok, []}
          end
        )

      # No targets at all (no running, no human-review, watch disabled) ->
      # the poller is never invoked. Only the per-cycle conditional issue-list
      # cache may differ; every other field, `approved_heads` included, must be
      # untouched.
      assert put_in(next.ci_lifecycle.poll_cache[:issue_list_cache], nil) ==
               put_in(state.ci_lifecycle.poll_cache[:issue_list_cache], nil)

      refute_receive :unexpected_watch_fetch, 100
      refute_receive {:unexpected_request, _url}, 100
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end
  end

  describe "per-comment command scan (one-off /aiur or @bot trigger)" do
    test "a trusted /aiur review comment on an unlabeled PR emits the pr#-keyed event" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        tracker_bot_account: "aiur-bot",
        pr_watch_enabled: true,
        pr_watch_command_prefix: "/aiur"
      )

      trust_authors!(["its-everdred"])

      :ok = Exchange.subscribe("ticket.733.pr.review_comment")

      # A REVIEW (line) comment — the primary "live review partner" case. The
      # PR number is derived from `pull_request_url`, NOT from any PR fetch.
      review_command = %{
        "id" => 90_001,
        "body" => "/aiur fix the nil case",
        "updated_at" => "2026-06-25T02:00:00Z",
        "user" => %{"login" => "its-everdred"},
        "pull_request_url" => "https://api.github.com/repos/owner/repo/pulls/733"
      }

      state = %Orchestrator.State{running: %{}, github_command_scan_since: "2026-06-25T00:00:00Z"}

      next =
        CommandScan.scan_pr_commands(state,
          repo: "owner/repo",
          command_scan_review_comment_fetcher: fn _opts -> {:ok, [review_command]} end,
          command_scan_issue_comment_fetcher: fn _opts -> {:ok, []} end
        )

      assert_receive {:event,
                      %{
                        topic: "ticket.733.pr.review_comment",
                        source: :github,
                        author_trusted?: true,
                        message: "/aiur fix the nil case",
                        issue_number: "733"
                      }},
                     500

      # The scan cursor advanced past the handled comment (−1s rewind), so the
      # same comment will not re-fire next cycle — the one-off guarantee.
      assert next.github_command_scan_since == "2026-06-25T01:59:59Z"
    after
      restore_trust!(codeowners_state())

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "a @<bot_account> mention in a PR conversation comment emits the reactivation event" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        tracker_bot_account: "aiur-bot",
        pr_watch_enabled: true
      )

      trust_authors!(["its-everdred"])

      :ok = Exchange.subscribe("ticket.734.pr.review_comment")

      # A conversation comment on a PR — `issue_url` gives the number and the
      # `/pull/` in `html_url` confirms it's a PR (not a plain issue).
      mention_comment = %{
        "id" => 90_002,
        "body" => "could you take a look @aiur-bot?",
        "updated_at" => "2026-06-25T03:00:00Z",
        "user" => %{"login" => "its-everdred"},
        "issue_url" => "https://api.github.com/repos/owner/repo/issues/734",
        "html_url" => "https://github.com/owner/repo/pull/734#issuecomment-90002"
      }

      CommandScan.scan_pr_commands(
        %Orchestrator.State{running: %{}, github_command_scan_since: "2026-06-25T00:00:00Z"},
        repo: "owner/repo",
        command_scan_review_comment_fetcher: fn _opts -> {:ok, []} end,
        command_scan_issue_comment_fetcher: fn _opts -> {:ok, [mention_comment]} end
      )

      assert_receive {:event, %{topic: "ticket.734.pr.review_comment", source: :github}}, 500
    after
      restore_trust!(codeowners_state())

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "a /aiur on a plain (non-PR) issue is out of scope — no event" do
      parent = self()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        tracker_bot_account: "aiur-bot",
        pr_watch_enabled: true
      )

      trust_authors!(["its-everdred"])

      :ok = Exchange.subscribe("ticket.736.pr.review_comment")

      # A plain ISSUE comment: `html_url` contains `/issues/`, not `/pull/`, so
      # the PR-number derivation returns nil and the comment is dropped.
      issue_comment = %{
        "id" => 90_020,
        "body" => "/aiur fix this",
        "updated_at" => "2026-06-25T05:00:00Z",
        "user" => %{"login" => "its-everdred"},
        "issue_url" => "https://api.github.com/repos/owner/repo/issues/736",
        "html_url" => "https://github.com/owner/repo/issues/736#issuecomment-90020"
      }

      CommandScan.scan_pr_commands(
        %Orchestrator.State{running: %{}, github_command_scan_since: "2026-06-25T00:00:00Z"},
        repo: "owner/repo",
        command_scan_review_comment_fetcher: fn _opts -> {:ok, []} end,
        command_scan_issue_comment_fetcher: fn _opts -> {:ok, [issue_comment]} end
      )
      |> tap(fn _ -> send(parent, :scan_done) end)

      refute_receive {:event, %{topic: "ticket.736.pr.review_comment"}}, 200
      assert_receive :scan_done, 500
    after
      restore_trust!(codeowners_state())

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "an untrusted author's /aiur is ignored (no event); the bot's own command is dropped" do
      parent = self()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        tracker_bot_account: "aiur-bot",
        pr_watch_enabled: true
      )

      # `its-everdred` is trusted; `stranger` is not. The bot is also trusted
      # (self-include) but must be dropped by the self-loop gate.
      trust_authors!(["its-everdred", "aiur-bot"])

      :ok = Exchange.subscribe("ticket.735.pr.review_comment")

      review_comments = [
        %{
          "id" => 90_010,
          "body" => "/aiur do the thing",
          "updated_at" => "2026-06-25T04:00:00Z",
          "user" => %{"login" => "stranger"},
          "pull_request_url" => "https://api.github.com/repos/owner/repo/pulls/735"
        },
        %{
          "id" => 90_011,
          "body" => "/aiur status",
          "updated_at" => "2026-06-25T04:01:00Z",
          "user" => %{"login" => "aiur-bot"},
          "pull_request_url" => "https://api.github.com/repos/owner/repo/pulls/735"
        }
      ]

      CommandScan.scan_pr_commands(
        %Orchestrator.State{running: %{}, github_command_scan_since: "2026-06-25T00:00:00Z"},
        repo: "owner/repo",
        command_scan_review_comment_fetcher: fn _opts -> {:ok, review_comments} end,
        command_scan_issue_comment_fetcher: fn _opts -> {:ok, []} end
      )
      |> tap(fn _ -> send(parent, :scan_done) end)

      # Neither the untrusted /aiur nor the bot's own /aiur produces a dispatch.
      refute_receive {:event, %{topic: "ticket.735.pr.review_comment"}}, 200
      assert_receive :scan_done, 500
    after
      restore_trust!(codeowners_state())

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "pr_watch disabled produces no scan and no events" do
      parent = self()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        tracker_bot_account: "aiur-bot"
      )

      state = %Orchestrator.State{running: %{}, github_command_scan_since: "2026-06-25T00:00:00Z"}

      next =
        CommandScan.scan_pr_commands(state,
          repo: "owner/repo",
          command_scan_review_comment_fetcher: fn _opts ->
            send(parent, :unexpected_command_scan_fetch)
            {:ok, []}
          end,
          command_scan_issue_comment_fetcher: fn _opts ->
            send(parent, :unexpected_command_scan_fetch)
            {:ok, []}
          end
        )

      # Feature off: the fetchers are never invoked and state is untouched.
      assert next == state
      refute_receive :unexpected_command_scan_fetch, 100
    end

    test "the command scan is bounded by distinct commanded PRs and the drop is logged" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        tracker_bot_account: "aiur-bot",
        pr_watch_enabled: true
      )

      trust_authors!(["its-everdred"])

      # Four distinct commanded PRs surface in one cursor window; the cap keeps
      # the lowest 2 PR numbers and logs the 2 dropped.
      for pr <- 1..4, do: Exchange.subscribe("ticket.#{pr}.pr.review_comment")

      review_comments =
        for n <- 1..4 do
          %{
            "id" => 90_100 + n,
            "body" => "/aiur handle this",
            "updated_at" => "2026-06-25T0#{n}:00:00Z",
            "user" => %{"login" => "its-everdred"},
            "pull_request_url" => "https://api.github.com/repos/owner/repo/pulls/#{n}"
          }
        end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          CommandScan.scan_pr_commands(
            %Orchestrator.State{running: %{}, github_command_scan_since: "2026-06-25T00:00:00Z"},
            repo: "owner/repo",
            command_scan_pull_request_limit: 2,
            command_scan_review_comment_fetcher: fn _opts -> {:ok, review_comments} end,
            command_scan_issue_comment_fetcher: fn _opts -> {:ok, []} end
          )
        end)

      # The two lowest-numbered PRs fire; the other two are capped out.
      assert_receive {:event, %{topic: "ticket.1.pr.review_comment"}}, 500
      assert_receive {:event, %{topic: "ticket.2.pr.review_comment"}}, 500
      refute_receive {:event, %{topic: "ticket.3.pr.review_comment"}}, 100
      refute_receive {:event, %{topic: "ticket.4.pr.review_comment"}}, 100

      assert log =~ "scan_pr_commands capped"
      assert log =~ "dropped=2"
    after
      restore_trust!(codeowners_state())

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end
  end

  describe "pause-request topic parser (subscriber wiring)" do
    test "extracts the identifier from a valid agent.pause.request topic" do
      assert {:ok, "100"} =
               EventTopics.parse_pause_request_topic("ticket.100.agent.pause.request")

      assert {:ok, "ABC-42"} =
               EventTopics.parse_pause_request_topic("ticket.ABC-42.agent.pause.request")
    end

    test "rejects unrelated topics" do
      for unrelated <- [
            "ticket.100.agent.pause",
            "ticket.100.agent.pause.requested",
            "ticket.100.pr.review_comment",
            "system.main.branch.push"
          ] do
        assert :nomatch = EventTopics.parse_pause_request_topic(unrelated)
      end
    end
  end

  describe "agent.pause.request awaits worker evidence" do
    test "running entry stays working until the worker confirms its pause" do
      issue_id = "issue-pause-1"
      identifier = "PAUSE-1"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :working}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = PushRouting.maybe_pause_on_request(state, identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :working
    end

    test "no-op when entry is already paused" do
      issue_id = "issue-pause-2"
      identifier = "PAUSE-2"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :paused}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      assert ^state = PushRouting.maybe_pause_on_request(state, identifier)
    end

    test "no-op when entry is :deactivated (don't bring back from the dead)" do
      issue_id = "issue-pause-3"
      identifier = "PAUSE-3"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "human-review", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :deactivated}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = PushRouting.maybe_pause_on_request(state, identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :deactivated
    end

    test "no-op when identifier isn't running" do
      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      assert ^state = PushRouting.maybe_pause_on_request(state, "UNKNOWN")
    end

    test "does not stamp paused_at before the worker confirms the pause" do
      issue_id = "issue-pause-clock"
      identifier = "PAUSE-CLOCK"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.add(DateTime.utc_now(), -120, :second),
            control: %{status: :working}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = PushRouting.maybe_pause_on_request(state, identifier)
      entry = next.running[issue_id]

      assert entry.control.status == :working
      refute Map.has_key?(entry, :paused_at)
    end
  end

  describe "subscribe_for_declared_blocker/2 (called from agent_runner on declare)" do
    test "blockee gets unblock readiness and branch-ref subscriptions immediately" do
      blockee = "BSDB-blockee-#{System.unique_integer([:positive])}"
      blocker = "BSDB-blocker-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        :ok = SubscriptionStore.stop(blockee)
        :ok = SubscriptionStore.stop(blocker)
      end)

      :ok = Orchestrator.subscribe_for_declared_blocker(blockee, blocker)

      %{subscribed_to: subs} = SubscriptionStore.snapshot(blockee)

      topics = Enum.map(subs, fn entry -> entry["topic"] || entry[:topic] end)

      assert "ticket.#{blocker}.agent.unblocked" in topics,
             "blockee must subscribe to explicit unblock readiness"

      assert "ticket.#{blocker}.branch.push" in topics,
             "blockee must retain the blocker branch ref for fetch and inspection"
    end

    test "second call is idempotent (no duplicate subscriptions)" do
      blockee = "BSDB-idem-blockee-#{System.unique_integer([:positive])}"
      blocker = "BSDB-idem-blocker-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        :ok = SubscriptionStore.stop(blockee)
        :ok = SubscriptionStore.stop(blocker)
      end)

      :ok = Orchestrator.subscribe_for_declared_blocker(blockee, blocker)
      :ok = Orchestrator.subscribe_for_declared_blocker(blockee, blocker)

      %{subscribed_to: subs} = SubscriptionStore.snapshot(blockee)

      push_subs =
        Enum.filter(subs, fn e ->
          (e["topic"] || e[:topic]) == "ticket.#{blocker}.branch.push"
        end)

      assert length(push_subs) == 1
    end

    test "accepts integer identifiers (the GitHub API path)" do
      blockee = "BSDB-int-#{System.unique_integer([:positive])}"
      blocker_int = System.unique_integer([:positive])

      on_exit(fn ->
        :ok = SubscriptionStore.stop(blockee)
        :ok = SubscriptionStore.stop(to_string(blocker_int))
      end)

      :ok = Orchestrator.subscribe_for_declared_blocker(blockee, blocker_int)

      %{subscribed_to: subs} = SubscriptionStore.snapshot(blockee)
      topics = Enum.map(subs, fn e -> e["topic"] || e[:topic] end)

      assert "ticket.#{blocker_int}.branch.push" in topics
    end
  end

  describe "stall watchdog skips paused / deactivated entries" do
    test "paused entry with stale last_codex_timestamp is NOT restarted" do
      issue_id = "issue-stall-paused"
      identifier = "STALL-P"

      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: spawn_link(fn -> Process.sleep(:infinity) end),
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: stale_at,
            last_codex_timestamp: stale_at,
            control: %{status: :paused}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      # 1ms timeout would trip on any entry whose elapsed > 1ms — but
      # the paused short-circuit must skip it BEFORE elapsed is computed.
      next = RuntimeWatchdog.apply_stall_check(state, 1)
      assert Map.has_key?(next.running, issue_id), "paused entry must not be restarted"
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
      assert next.retry_attempts == %{}, "no retry should be scheduled"
    end

    test "deactivated entry with stale last_codex_timestamp is NOT restarted" do
      issue_id = "issue-stall-deact"
      identifier = "STALL-D"

      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "human-review", identifier: identifier},
            started_at: stale_at,
            last_codex_timestamp: stale_at,
            control: %{status: :deactivated}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = RuntimeWatchdog.apply_stall_check(state, 1)
      assert Map.has_key?(next.running, issue_id)
      assert get_in(next.running, [issue_id, :control, :status]) == :deactivated
      assert next.retry_attempts == %{}
    end

    test "actively-working entry with stale last_codex_timestamp IS restarted" do
      issue_id = "issue-stall-working"
      identifier = "STALL-W"

      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)

      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: worker_pid,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: stale_at,
            last_codex_timestamp: stale_at,
            control: %{status: :working}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = RuntimeWatchdog.apply_stall_check(state, 1)
      refute Map.has_key?(next.running, issue_id), "working+stale entry must be restarted"

      assert %{identifier: ^identifier, error: "stalled" <> _} =
               Map.get(next.retry_attempts, issue_id)
    end

    test "claude-hook activity refreshes liveness so an active RC-claude entry is NOT stall-restarted" do
      # An RC-claude agent works via lifecycle hooks, which never produce a
      # codex update — so `last_codex_timestamp` stays at `started_at` while
      # the agent is busy. A hook firing must refresh liveness so the stall
      # watchdog does not kill a working agent.
      issue_id = "issue-hook-active"
      identifier = "STALL-HOOK"

      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)
      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: worker_pid,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: stale_at,
            last_codex_timestamp: stale_at,
            control: %{status: :working}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      # A claude hook fires for this agent -> liveness refreshed to now.
      refreshed = Orchestrator.note_agent_activity_state(state, identifier)

      next = RuntimeWatchdog.apply_stall_check(refreshed, 60_000)

      assert Map.has_key?(next.running, issue_id), "hook-active entry must NOT be stall-restarted"
      assert next.retry_attempts == %{}
    end

    test "note_agent_activity_state is a no-op for an unknown identifier" do
      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      assert Orchestrator.note_agent_activity_state(state, "NOPE") == state
    end
  end

  describe "ticket.<blocker>.agent.unblocked auto-resumes paused blockees" do
    setup do
      reset_branch_refs()

      # Isolate subscription persistence to a unique tmp dir. `attach` loads
      # any `<repo>.<identifier>.subscriptions.json` left on disk, and the
      # `unique_integer` identifier can repeat across separate `mix test`
      # runs (the counter resets per VM boot). Without isolation a sibling
      # test's persisted `ticket.99.agent.unblocked` subscription leaks back in
      # and wrongly auto-resumes a blockee that should stay paused.
      tmp_dir =
        Path.join(System.tmp_dir!(), "aiur_blockee_subscr_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      original_log_file = Application.get_env(:aiur, :log_file)
      Application.put_env(:aiur, :log_file, Path.join(tmp_dir, "aiur.log"))

      identifier = "BLOCKEE-#{System.unique_integer([:positive])}"
      :ok = SubscriptionStore.attach(identifier)

      on_exit(fn ->
        reset_branch_refs()
        :ok = SubscriptionStore.stop(identifier)

        if original_log_file do
          Application.put_env(:aiur, :log_file, original_log_file)
        else
          Application.delete_env(:aiur, :log_file)
        end

        File.rm_rf(tmp_dir)
      end)

      fake_pid = spawn_link(fn -> fake_agent_loop() end)

      %{identifier: identifier, fake_pid: fake_pid}
    end

    defp fake_agent_loop do
      receive do
        _ -> fake_agent_loop()
      end
    end

    defp blocker_ref, do: "refs/heads/aiur/99-dependency"
    defp blocker_sha, do: String.duplicate("a", 40)

    # BranchRefStore persists through a disk-backed GenServer. Under full-suite
    # IO load a write can transiently fail; on failure it rolls the in-memory
    # state back and queues a retry (production recovers the same way via
    # PushRouting.reconcile_durable_unblocks). `await_settled/0` blocks on
    # that retry actually landing instead of guessing at a wall-clock
    # deadline, so a saturated box does not surface as a spurious failure of
    # an assertion that reads the store immediately.
    defp reset_branch_refs do
      BranchRefStore.reset()
      :ok = BranchRefStore.await_settled()
    end

    defp record_blocker_ref do
      BranchRefStore.record(blocker_ref(), blocker_sha())
      :ok = BranchRefStore.await_settled()
    end

    defp assert_ready_unblock(expected) do
      :ok = BranchRefStore.await_settled()
      assert BranchRefStore.ready_unblock("99") == expected
    end

    defp blocker_pause_fields do
      %{
        paused_reason: :blocker_dependency,
        blocker_pause_generation: 1,
        blocker_pause: %{blocker_identifier: "99", generation: 1}
      }
    end

    defp control_issue(issue_id, identifier, state \\ "in-progress") do
      %Issue{
        id: issue_id,
        state: state,
        identifier: identifier,
        tracker_identity: tracker_identity(issue_id)
      }
    end

    defp confirm_pending_control(state, issue_id, status) do
      request_id = state.control_lifecycle.pending[issue_id]
      request = state.control_lifecycle.records[request_id]

      assert {:noreply, next} =
               PauseResume.handle_worker_control_state(state, issue_id, status, %{
                 request_id: request_id,
                 generation: request.generation
               })

      next
    end

    defp with_blocker_push(entry) do
      record_blocker_ref()
      entry
    end

    test "dependency pause requests establish a blocker-specific generation", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      issue_id = "issue-dependency-pause"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: fake_pid,
            ref: nil,
            identifier: identifier,
            issue: control_issue(issue_id, identifier),
            started_at: DateTime.utc_now(),
            control: confirmed_control(:working)
          }
        },
        claimed: MapSet.new([issue_id]),
        max_concurrent_agents: 6
      }

      paused =
        PushRouting.maybe_pause_on_request(state, identifier, %{
          payload: %{reason: "dependency", blocker_identifier: "99"}
        })

      assert get_in(paused.running, [issue_id, :control, :status]) == :working
      assert get_in(paused.running, [issue_id, :pending_pause_reason, :reason]) == :blocker_dependency
      assert get_in(paused.running, [issue_id, :blocker_pause]) == %{blocker_identifier: "99", generation: 1}

      paused = confirm_pending_control(paused, issue_id, :paused)
      assert get_in(paused.running, [issue_id, :control, :status]) == :paused
      assert get_in(paused.running, [issue_id, :paused_reason]) == :blocker_dependency

      generic = PushRouting.maybe_pause_on_request(state, identifier, %{})
      assert get_in(generic.running, [issue_id, :control, :status]) == :working
      assert get_in(generic.running, [issue_id, :pending_pause_reason, :reason]) == :agent_pause_request
      refute Map.has_key?(generic.running[issue_id], :blocker_pause)

      generic = confirm_pending_control(generic, issue_id, :paused)
      assert get_in(generic.running, [issue_id, :paused_reason]) == :agent_pause_request
    end

    test "real control transitions replace blocker context before final unblock", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      :ok = SubscriptionStore.add_subscription(identifier, "ticket.99.agent.unblocked", "blocker:auto")
      record_blocker_ref()

      issue_id = "issue-replaced-pause"
      issue = control_issue(issue_id, identifier, "ci-wait")

      entry =
        %{
          pid: fake_pid,
          ref: nil,
          identifier: identifier,
          issue: issue,
          started_at: DateTime.utc_now(),
          control: confirmed_control(:paused),
          pending_auto_resume: %{pause_generation: 1}
        }
        |> Map.merge(blocker_pause_fields())

      state = %Orchestrator.State{
        running: %{issue_id => entry},
        claimed: MapSet.new([issue_id]),
        max_concurrent_agents: 6
      }

      tracker_paused = PauseResume.pause_issue_for_label_override(state, issue)
      assert tracker_paused.running[issue_id].paused_reason == :blocker_dependency
      assert Map.has_key?(tracker_paused.running[issue_id], :blocker_pause)
      assert Map.has_key?(tracker_paused.running[issue_id], :pending_auto_resume)

      transitions = [
        {:ci_wait, fn current -> CiLifecycle.pause_issue_for_ci_wait(current, issue) end},
        {:operator_pause, fn current -> elem(PauseResume.pause_agent_reply(current, identifier), 1) end},
        {:max_agent_duration,
         fn current ->
           paused_entry = Map.put(current.running[issue_id], :paused_reason, :max_agent_duration)
           PauseResume.transition_control_status(current, paused_entry, :paused, "max_agent_duration")
         end}
      ]

      for {reason, transition} <- transitions do
        transitioned = transition.(state)
        assert transitioned.running[issue_id].paused_reason == reason
        refute Map.has_key?(transitioned.running[issue_id], :blocker_pause)
        refute Map.has_key?(transitioned.running[issue_id], :pending_auto_resume)

        next =
          EventTopics.route(transitioned, %{
            topic: "ticket.99.agent.unblocked",
            payload: %{ref: blocker_ref(), sha: blocker_sha()}
          })

        assert get_in(next.running, [issue_id, :control, :status]) == :paused
      end
    end

    test "direct final unblock requires the current blocker-pause reason and generation", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      :ok = SubscriptionStore.add_subscription(identifier, "ticket.99.agent.unblocked", "blocker:auto")
      record_blocker_ref()
      issue_id = "issue-current-generation"

      matching_entry =
        %{
          pid: fake_pid,
          ref: nil,
          identifier: identifier,
          issue: control_issue(issue_id, identifier),
          started_at: DateTime.utc_now(),
          control: confirmed_control(:paused)
        }
        |> Map.merge(blocker_pause_fields())

      mismatched_entries = [
        Map.put(matching_entry, :paused_reason, :operator_pause),
        put_in(matching_entry, [:blocker_pause, :generation], 2)
      ]

      for entry <- mismatched_entries do
        state = %Orchestrator.State{
          running: %{issue_id => entry},
          claimed: MapSet.new([issue_id]),
          max_concurrent_agents: 6
        }

        next =
          EventTopics.route(state, %{
            topic: "ticket.99.agent.unblocked",
            payload: %{ref: blocker_ref(), sha: blocker_sha()}
          })

        assert get_in(next.running, [issue_id, :control, :status]) == :paused
      end
    end

    test "branch push before consumer subscription corroborates later final unblock", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      empty = %Orchestrator.State{running: %{}}

      EventTopics.route(empty, %{
        topic: "ticket.99.branch.push",
        ref: blocker_ref(),
        sha: blocker_sha()
      })

      :ok = SubscriptionStore.add_subscription(identifier, "ticket.99.agent.unblocked", "blocker:auto")
      issue_id = "issue-push-before-subscribe"

      entry =
        %{
          pid: fake_pid,
          ref: nil,
          identifier: identifier,
          issue: control_issue(issue_id, identifier),
          started_at: DateTime.utc_now(),
          control: confirmed_control(:paused)
        }
        |> Map.merge(blocker_pause_fields())

      state = %Orchestrator.State{
        running: %{issue_id => entry},
        claimed: MapSet.new([issue_id]),
        max_concurrent_agents: 6
      }

      next =
        EventTopics.route(state, %{
          topic: "ticket.99.agent.unblocked",
          payload: %{ref: blocker_ref(), sha: blocker_sha()}
        })

      assert get_in(next.running, [issue_id, :control, :status]) == :paused

      assert %{action: :resume, status: :accepted} =
               next.control_lifecycle.records[next.control_lifecycle.pending[issue_id]]

      next = confirm_pending_control(next, issue_id, :working)
      assert get_in(next.running, [issue_id, :control, :status]) == :working
    end

    test "ready unblock survives restart ordering until the consumer is restored", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      empty = %Orchestrator.State{running: %{}}

      empty =
        EventTopics.route(empty, %{
          topic: "ticket.99.agent.unblocked",
          payload: %{ref: blocker_ref(), sha: blocker_sha()}
        })

      EventTopics.route(empty, %{
        topic: "ticket.99.branch.push",
        ref: blocker_ref(),
        sha: blocker_sha()
      })

      assert_ready_unblock(%{ref: blocker_ref(), sha: blocker_sha()})
      :ok = SubscriptionStore.add_subscription(identifier, "ticket.99.agent.unblocked", "blocker:auto")
      issue_id = "issue-restored-after-ready"

      entry =
        %{
          pid: fake_pid,
          ref: nil,
          identifier: identifier,
          issue: control_issue(issue_id, identifier),
          started_at: DateTime.utc_now(),
          control: confirmed_control(:paused)
        }
        |> Map.merge(blocker_pause_fields())

      restored = %Orchestrator.State{
        running: %{issue_id => entry},
        claimed: MapSet.new([issue_id]),
        max_concurrent_agents: 6
      }

      resumed = PushRouting.reconcile_pending_auto_resumes(restored)
      assert get_in(resumed.running, [issue_id, :control, :status]) == :paused
      resumed = confirm_pending_control(resumed, issue_id, :working)
      assert get_in(resumed.running, [issue_id, :control, :status]) == :working
      assert_ready_unblock(nil)
    end

    test "parked blockee ignores branch push then consumes explicit unblocked and resumes", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      :ok =
        SubscriptionStore.add_subscription(
          identifier,
          "ticket.99.agent.unblocked",
          "blocker:auto"
        )

      issue_id = "issue-blockee-1"

      state = %Orchestrator.State{
        running: %{
          issue_id =>
            %{
              pid: fake_pid,
              ref: nil,
              identifier: identifier,
              issue: control_issue(issue_id, identifier),
              started_at: DateTime.utc_now(),
              control: confirmed_control(:paused)
            }
            |> Map.merge(blocker_pause_fields())
            |> with_blocker_push()
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      after_push = EventTopics.route(state, %{topic: "ticket.99.branch.push", ref: blocker_ref(), sha: blocker_sha()})
      assert get_in(after_push.running, [issue_id, :control, :status]) == :paused

      next =
        EventTopics.route(after_push, %{
          topic: "ticket.99.agent.unblocked",
          payload: %{ref: blocker_ref(), sha: blocker_sha()}
        })

      assert get_in(next.running, [issue_id, :control, :status]) == :paused
      next = confirm_pending_control(next, issue_id, :working)
      assert get_in(next.running, [issue_id, :control, :status]) == :working
    end

    test "unblock before pause is retained then consumed exactly once", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      :ok =
        SubscriptionStore.add_subscription(
          identifier,
          "ticket.99.agent.unblocked",
          "blocker:auto"
        )

      issue_id = "issue-blockee-2"

      state = %Orchestrator.State{
        running: %{
          issue_id =>
            %{
              pid: fake_pid,
              ref: nil,
              identifier: identifier,
              issue: control_issue(issue_id, identifier),
              started_at: DateTime.utc_now(),
              control: confirmed_control(:working)
            }
            |> Map.merge(blocker_pause_fields())
            |> with_blocker_push()
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = PushRouting.apply_agent_unblocked(state, "99")
      assert get_in(next.running, [issue_id, :control, :status]) == :working
      assert get_in(next.running, [issue_id, :pending_auto_resume, :blocker_identifier]) == "99"

      paused = put_in(next.running[issue_id].control.status, :paused)
      resumed = PushRouting.reconcile_pending_auto_resumes(paused)

      assert get_in(resumed.running, [issue_id, :control, :status]) == :paused
      assert get_in(resumed.running, [issue_id, :pending_auto_resume, :blocker_identifier]) == "99"
      assert_ready_unblock(%{ref: blocker_ref(), sha: blocker_sha()})
      resumed = confirm_pending_control(resumed, issue_id, :working)
      assert get_in(resumed.running, [issue_id, :control, :status]) == :working
      refute Map.has_key?(resumed.running[issue_id], :pending_auto_resume)

      assert PushRouting.reconcile_pending_auto_resumes(resumed) == resumed
      assert PushRouting.apply_agent_unblocked(resumed, "99") == resumed
    end

    test "unblock stays durable until every subscribed consumer reaches its matching pause", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      late_identifier = "LATE-BLOCKEE-#{System.unique_integer([:positive])}"
      :ok = SubscriptionStore.attach(late_identifier)

      on_exit(fn -> SubscriptionStore.stop(late_identifier) end)

      for blockee <- [identifier, late_identifier] do
        :ok =
          SubscriptionStore.add_subscription(
            blockee,
            "ticket.99.agent.unblocked",
            "blocker:auto"
          )
      end

      first_issue_id = "issue-first-blockee"
      late_issue_id = "issue-late-blockee"

      first_entry = %{
        pid: fake_pid,
        ref: nil,
        identifier: identifier,
        issue: control_issue(first_issue_id, identifier),
        started_at: DateTime.utc_now(),
        control: confirmed_control(:paused)
      }

      late_pid = spawn_link(fn -> fake_agent_loop() end)

      late_entry = %{
        pid: late_pid,
        ref: nil,
        identifier: late_identifier,
        issue: control_issue(late_issue_id, late_identifier),
        started_at: DateTime.utc_now(),
        control: confirmed_control(:working)
      }

      state = %Orchestrator.State{
        running: %{
          first_issue_id => Map.merge(first_entry, blocker_pause_fields()),
          late_issue_id => late_entry
        },
        claimed: MapSet.new([first_issue_id, late_issue_id]),
        max_concurrent_agents: 6
      }

      record_blocker_ref()

      after_unblock =
        EventTopics.route(state, %{
          topic: "ticket.99.agent.unblocked",
          payload: %{ref: blocker_ref(), sha: blocker_sha()}
        })

      assert get_in(after_unblock.running, [first_issue_id, :control, :status]) == :paused
      assert get_in(after_unblock.running, [late_issue_id, :control, :status]) == :working

      after_unblock = confirm_pending_control(after_unblock, first_issue_id, :working)
      assert get_in(after_unblock.running, [first_issue_id, :control, :status]) == :working

      assert_ready_unblock(%{ref: blocker_ref(), sha: blocker_sha()})

      after_late_pause =
        EventTopics.route(after_unblock, %{
          topic: "ticket.#{late_identifier}.agent.pause.request",
          payload: %{reason: "dependency", blocker_identifier: "99"}
        })

      assert get_in(after_late_pause.running, [late_issue_id, :control, :status]) == :working
      after_late_pause = confirm_pending_control(after_late_pause, late_issue_id, :paused)
      assert get_in(after_late_pause.running, [late_issue_id, :control, :status]) == :paused

      reconciled = PushRouting.reconcile_pending_auto_resumes(after_late_pause)

      assert get_in(reconciled.running, [late_issue_id, :control, :status]) == :paused
      reconciled = confirm_pending_control(reconciled, late_issue_id, :working)
      assert get_in(reconciled.running, [late_issue_id, :control, :status]) == :working
      assert_ready_unblock(nil)
    end

    test "unblock stays durable for a declared consumer that has not started yet", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      late_identifier = "DECLARED-BLOCKEE-#{System.unique_integer([:positive])}"
      late_issue_id = "issue-declared-blockee"
      :ok = SubscriptionStore.attach(late_identifier)

      on_exit(fn -> SubscriptionStore.stop(late_identifier) end)

      for blockee <- [identifier, late_identifier] do
        :ok =
          SubscriptionStore.add_subscription(
            blockee,
            "ticket.99.agent.unblocked",
            "blocker:auto"
          )
      end

      first_issue_id = "issue-running-blockee"

      first_entry =
        %{
          pid: fake_pid,
          ref: nil,
          identifier: identifier,
          issue: control_issue(first_issue_id, identifier),
          started_at: DateTime.utc_now(),
          control: confirmed_control(:paused)
        }
        |> Map.merge(blocker_pause_fields())

      declared_issue = %Issue{
        id: late_issue_id,
        identifier: late_identifier,
        state: "in-progress",
        tracker_identity: tracker_identity(late_issue_id),
        blocked_by: [%{id: "blocker-issue", identifier: "99", state: "in-progress"}]
      }

      state = %Orchestrator.State{
        running: %{first_issue_id => first_entry},
        last_polled_issues: %{late_issue_id => declared_issue},
        claimed: MapSet.new([first_issue_id]),
        max_concurrent_agents: 6
      }

      record_blocker_ref()

      after_unblock =
        EventTopics.route(state, %{
          topic: "ticket.99.agent.unblocked",
          payload: %{ref: blocker_ref(), sha: blocker_sha()}
        })

      assert get_in(after_unblock.running, [first_issue_id, :control, :status]) == :paused
      after_unblock = confirm_pending_control(after_unblock, first_issue_id, :working)
      assert get_in(after_unblock.running, [first_issue_id, :control, :status]) == :working
      assert_ready_unblock(%{ref: blocker_ref(), sha: blocker_sha()})

      late_pid = spawn_link(fn -> fake_agent_loop() end)

      late_entry =
        %{
          pid: late_pid,
          ref: nil,
          identifier: late_identifier,
          issue: declared_issue,
          started_at: DateTime.utc_now(),
          control: confirmed_control(:paused)
        }
        |> Map.merge(blocker_pause_fields())

      started = %{
        after_unblock
        | running: Map.put(after_unblock.running, late_issue_id, late_entry),
          claimed: MapSet.put(after_unblock.claimed, late_issue_id)
      }

      reconciled = PushRouting.reconcile_pending_auto_resumes(started)

      assert get_in(reconciled.running, [late_issue_id, :control, :status]) == :paused
      reconciled = confirm_pending_control(reconciled, late_issue_id, :working)
      assert get_in(reconciled.running, [late_issue_id, :control, :status]) == :working
      assert_ready_unblock(nil)
    end

    test "final unblock requires canonical ref and SHA corroborated by branch push", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      :ok = SubscriptionStore.add_subscription(identifier, "ticket.99.agent.unblocked", "blocker:auto")
      issue_id = "issue-corroborated-unblock"

      entry =
        %{
          pid: fake_pid,
          ref: nil,
          identifier: identifier,
          issue: control_issue(issue_id, identifier),
          started_at: DateTime.utc_now(),
          control: confirmed_control(:paused)
        }
        |> Map.merge(blocker_pause_fields())

      state = %Orchestrator.State{
        running: %{issue_id => entry},
        claimed: MapSet.new([issue_id]),
        max_concurrent_agents: 6
      }

      invalid_payloads = [
        %{},
        %{ref: blocker_ref()},
        %{sha: blocker_sha()},
        %{ref: 123, sha: blocker_sha()},
        %{ref: blocker_ref(), sha: 123},
        %{ref: "aiur/99-dependency", sha: blocker_sha()},
        %{ref: blocker_ref(), sha: "short"}
      ]

      for payload <- invalid_payloads do
        next = EventTopics.route(state, %{topic: "ticket.99.agent.unblocked", payload: payload})
        assert get_in(next.running, [issue_id, :control, :status]) == :paused
      end

      unblock = %{topic: "ticket.99.agent.unblocked", payload: %{ref: blocker_ref(), sha: blocker_sha()}}
      awaiting_push = EventTopics.route(state, unblock)
      assert get_in(awaiting_push.running, [issue_id, :control, :status]) == :paused

      mismatches = [
        %{ref: "refs/heads/aiur/99-other", sha: blocker_sha()},
        %{ref: blocker_ref(), sha: String.duplicate("b", 40)}
      ]

      for payload <- mismatches do
        next = EventTopics.route(awaiting_push, %{topic: "ticket.99.agent.unblocked", payload: payload})
        assert get_in(next.running, [issue_id, :control, :status]) == :paused
      end

      pushed = EventTopics.route(awaiting_push, %{topic: "ticket.99.branch.push", ref: blocker_ref(), sha: blocker_sha()})
      assert get_in(pushed.running, [issue_id, :control, :status]) == :paused
      pushed = confirm_pending_control(pushed, issue_id, :working)
      assert get_in(pushed.running, [issue_id, :control, :status]) == :working
      assert EventTopics.route(pushed, %{topic: "ticket.99.branch.push", ref: blocker_ref(), sha: blocker_sha()}) == pushed
    end

    test "retained readiness only drains its matching blocker-pause generation", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      :ok = SubscriptionStore.add_subscription(identifier, "ticket.99.agent.unblocked", "blocker:auto")
      issue_id = "issue-pause-generation"

      entry =
        %{
          pid: fake_pid,
          ref: nil,
          identifier: identifier,
          issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
          started_at: DateTime.utc_now(),
          control: %{status: :working}
        }
        |> Map.merge(blocker_pause_fields())
        |> with_blocker_push()

      state = %Orchestrator.State{
        running: %{issue_id => entry},
        claimed: MapSet.new([issue_id]),
        max_concurrent_agents: 6
      }

      ready = PushRouting.apply_agent_unblocked(state, "99")
      assert get_in(ready.running, [issue_id, :pending_auto_resume, :pause_generation]) == 1

      for reason <- [:operator_pause, :label_override, :max_agent_duration, :ci_wait] do
        unrelated =
          ready
          |> put_in([Access.key(:running), issue_id, :control, :status], :paused)
          |> put_in([Access.key(:running), issue_id, :paused_reason], reason)

        reconciled = PushRouting.reconcile_pending_auto_resumes(unrelated)
        assert get_in(reconciled.running, [issue_id, :control, :status]) == :paused
        refute Map.has_key?(reconciled.running[issue_id], :pending_auto_resume)
      end

      next_generation =
        ready
        |> put_in([Access.key(:running), issue_id, :control, :status], :paused)
        |> put_in([Access.key(:running), issue_id, :blocker_pause, :generation], 2)

      reconciled = PushRouting.reconcile_pending_auto_resumes(next_generation)
      assert get_in(reconciled.running, [issue_id, :control, :status]) == :paused
      refute Map.has_key?(reconciled.running[issue_id], :pending_auto_resume)

      advanced_counter =
        ready
        |> put_in([Access.key(:running), issue_id, :control, :status], :paused)
        |> put_in([Access.key(:running), issue_id, :blocker_pause_generation], 2)

      reconciled = PushRouting.reconcile_pending_auto_resumes(advanced_counter)
      assert get_in(reconciled.running, [issue_id, :control, :status]) == :paused
      refute Map.has_key?(reconciled.running[issue_id], :pending_auto_resume)
    end

    test "provisional unblocked payloads never resume or stamp readiness", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      :ok = SubscriptionStore.add_subscription(identifier, "ticket.99.agent.unblocked", "blocker:auto")

      issue_id = "issue-provisional-unblock"

      state = %Orchestrator.State{
        running: %{
          issue_id =>
            %{
              pid: fake_pid,
              ref: nil,
              identifier: identifier,
              issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :paused}
            }
            |> Map.merge(blocker_pause_fields())
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      record_blocker_ref()

      events = [
        %{topic: "ticket.99.agent.unblocked", temporary_stub: true, ref: blocker_ref(), sha: blocker_sha()},
        %{"temporary_stub" => true, "ref" => blocker_ref(), "sha" => blocker_sha(), topic: "ticket.99.agent.unblocked"},
        %{topic: "ticket.99.agent.unblocked", payload: %{temporary_stub: true, ref: blocker_ref(), sha: blocker_sha()}},
        %{"payload" => %{"temporary_stub" => true, "ref" => blocker_ref(), "sha" => blocker_sha()}, topic: "ticket.99.agent.unblocked"}
      ]

      for event <- events do
        next = EventTopics.route(state, event)
        assert get_in(next.running, [issue_id, :control, :status]) == :paused
        refute Map.has_key?(next.running[issue_id], :pending_auto_resume)
      end
    end

    test "paused blockee NOT subscribed to this blocker stays paused", %{
      identifier: identifier,
      fake_pid: fake_pid
    } do
      # Subscribe to a DIFFERENT blocker's unblock; the 99 unblock should be
      # treated as not relevant to this entry.
      :ok =
        SubscriptionStore.add_subscription(
          identifier,
          "ticket.42.agent.unblocked",
          "blocker:auto"
        )

      issue_id = "issue-blockee-3"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: fake_pid,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :paused}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = PushRouting.apply_agent_unblocked(state, "99")
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
    end

    test "auto-resume waits to refresh last_codex_timestamp until the worker confirms",
         %{identifier: identifier, fake_pid: fake_pid} do
      # Reproduces the live --test3 run #3 race: a blockee paused for
      # >stall_timeout_ms then requested a resume back to :working, only to
      # be killed by the very next stall watchdog scan because its
      # `last_codex_timestamp` still reflected the pre-pause activity.
      :ok =
        SubscriptionStore.add_subscription(
          identifier,
          "ticket.99.agent.unblocked",
          "blocker:auto"
        )

      issue_id = "issue-resume-timestamp"

      # Last codex activity is 14 minutes old — well past the default
      # 5-minute stall window.
      stale_at = DateTime.add(DateTime.utc_now(), -840, :second)

      state = %Orchestrator.State{
        running: %{
          issue_id =>
            %{
              pid: fake_pid,
              ref: nil,
              identifier: identifier,
              issue: %Issue{
                id: issue_id,
                state: "in-progress",
                identifier: identifier,
                tracker_identity: tracker_identity(issue_id)
              },
              started_at: stale_at,
              last_codex_timestamp: stale_at,
              control: confirmed_control(:paused),
              paused_at: stale_at
            }
            |> Map.merge(blocker_pause_fields())
            |> with_blocker_push()
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = PushRouting.apply_agent_unblocked(state, "99")

      entry = next.running[issue_id]
      assert entry.control.status == :paused
      assert entry.last_codex_timestamp == stale_at

      assert %{action: :resume, status: :accepted} =
               next.control_lifecycle.records[next.control_lifecycle.pending[issue_id]]
    end

    test "blocker's own entry is never resumed against its own unblocked event", %{
      identifier: blocker_identifier,
      fake_pid: fake_pid
    } do
      # An agent could theoretically be subscribed to its own unblock topic
      # (via aiur_subscribe). Defensive: don't resume the publisher itself.
      :ok =
        SubscriptionStore.add_subscription(
          blocker_identifier,
          "ticket.#{blocker_identifier}.agent.unblocked",
          "manual:agent"
        )

      issue_id = "issue-blocker-self"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: fake_pid,
            ref: nil,
            identifier: blocker_identifier,
            issue: %Issue{
              id: issue_id,
              state: "in-progress",
              identifier: blocker_identifier
            },
            started_at: DateTime.utc_now(),
            control: %{status: :paused}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = PushRouting.apply_agent_unblocked(state, blocker_identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
    end
  end

  describe "REPL session teardown tracking (U7)" do
    test "{:repl_session_runtime, ...} records the pane id + os pid on the running entry" do
      issue_id = "issue-repl-track"
      identifier = "RPL-1"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :working},
            repl_pane_id: nil,
            repl_os_pid: nil
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      {:noreply, next} =
        Orchestrator.handle_info(
          {:repl_session_runtime, issue_id, %{pane_id: "%77", os_pid: 4242}},
          state
        )

      entry = next.running[issue_id]
      assert entry.repl_pane_id == "%77"
      assert entry.repl_os_pid == 4242
    end

    test "{:repl_session_runtime, ...} for an unknown issue is a no-op" do
      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      assert {:noreply, ^state} =
               Orchestrator.handle_info(
                 {:repl_session_runtime, "nope", %{pane_id: "%1", os_pid: 1}},
                 state
               )
    end

    test "deactivate tears down a tracked REPL session and still deactivates the entry" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-orch-repl-teardown-#{System.unique_integer([:positive])}"
        )

      issue_id = "issue-repl-teardown"
      issue_identifier = "RPT-1"

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        agent_pid =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: agent_pid,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "in-progress", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :working},
              # os pid nil keeps graceful_kill a no-op; the pane kill targets a
              # bogus id the real tmux server rejects harmlessly — the point is
              # the deactivate path's kill_repl_session runs cleanly.
              repl_pane_id: "%repl-bogus",
              repl_os_pid: nil
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "human-review",
          title: "PR up for review",
          description: "",
          labels: []
        }

        updated_state = Reconciler.reconcile_running_issue_states([issue], state)

        entry = Map.fetch!(updated_state.running, issue_id)
        assert get_in(entry, [:control, :status]) == :deactivated
        refute Process.alive?(agent_pid)
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "whole-app shutdown reaping (terminate/2)" do
    @tag skip: @pgrep_skip_reason
    test "reaps every running entry's headless agent subtree on shutdown" do
      # Mirror the headless backend: a `bash -lc` wrapper that forks a child
      # it never execs. On whole-app shutdown the supervisor brutally kills
      # the AgentRunner task (skipping `after stop_session`), so without a
      # terminate/2 reap the child reparents to init and keeps committing.
      command = "sleep 600 & printf 'up\\n'; wait"

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(System.find_executable("bash"))},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            line: 64_000
          ]
        )

      {:os_pid, bash_pid} = :erlang.port_info(port, :os_pid)
      assert_receive {^port, {:data, {:eol, "up"}}}, 2_000

      child_pid = shutdown_wait_for_child(bash_pid, 2_000)

      on_exit(fn ->
        for p <- [bash_pid, child_pid], is_integer(p) do
          System.cmd("kill", ["-KILL", Integer.to_string(p)], stderr_to_stdout: true)
        end
      end)

      assert is_integer(child_pid)
      assert shutdown_os_alive?(child_pid)

      issue_id = "issue-shutdown-reap"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: "SHD-1",
            issue: %Issue{id: issue_id, state: "in-progress", identifier: "SHD-1"},
            started_at: DateTime.utc_now(),
            control: %{status: :working},
            headless_os_pid: bash_pid
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      assert :ok = Orchestrator.terminate(:shutdown, state)

      refute shutdown_os_alive?(bash_pid)
      refute shutdown_os_alive?(child_pid)
    end

    defp shutdown_wait_for_child(parent, budget_ms) do
      deadline = System.monotonic_time(:millisecond) + budget_ms
      do_shutdown_wait_for_child(parent, deadline)
    end

    defp do_shutdown_wait_for_child(parent, deadline) do
      first_child =
        case System.cmd("pgrep", ["-P", Integer.to_string(parent)], stderr_to_stdout: true) do
          {out, 0} -> out |> String.split() |> Enum.map(&String.to_integer/1) |> List.first()
          _ -> nil
        end

      cond do
        is_integer(first_child) ->
          first_child

        System.monotonic_time(:millisecond) >= deadline ->
          nil

        true ->
          Process.sleep(25)
          do_shutdown_wait_for_child(parent, deadline)
      end
    end

    defp shutdown_os_alive?(pid),
      do: match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
  end

  describe "branch-push topic parser (subscriber wiring)" do
    test "extracts the identifier from a valid ticket.<id>.branch.push topic" do
      assert {:ok, "99"} =
               EventTopics.parse_branch_push_topic("ticket.99.branch.push")
    end

    test "rejects system-branch pushes (not ticket-scoped)" do
      assert :nomatch =
               EventTopics.parse_branch_push_topic("system.main.branch.push")
    end

    test "rejects nearby topics" do
      for unrelated <- [
            "ticket.99.branch.force-push",
            "ticket.99.pr.opened",
            "ticket.99.agent.pause.request"
          ] do
        assert :nomatch = EventTopics.parse_branch_push_topic(unrelated)
      end
    end
  end

  describe "system default-branch push notifies without terminating" do
    test "topic parser extracts the branch from a system branch push" do
      assert {:ok, "main"} =
               EventTopics.parse_system_branch_push_topic("system.main.branch.push")

      assert :nomatch =
               EventTopics.parse_system_branch_push_topic("ticket.99.branch.push")
    end

    test "default branch push leaves active and paused agents running and preserves claims" do
      issue_a = %Issue{id: "issue-main-a", identifier: "560", state: "in-progress"}
      issue_b = %Issue{id: "issue-main-b", identifier: "561", state: "in-progress"}
      issue_paused = %Issue{id: "issue-paused", identifier: "562", state: "in-progress"}

      pid_a = spawn(fn -> Process.sleep(:infinity) end)
      pid_b = spawn(fn -> Process.sleep(:infinity) end)
      pid_paused = spawn(fn -> Process.sleep(:infinity) end)
      started_at = DateTime.utc_now()

      state = %Orchestrator.State{
        running: %{
          issue_a.id => %{
            pid: pid_a,
            ref: nil,
            identifier: issue_a.identifier,
            issue: issue_a,
            control: %{status: :working},
            started_at: started_at
          },
          issue_b.id => %{
            pid: pid_b,
            ref: nil,
            identifier: issue_b.identifier,
            issue: issue_b,
            control: %{status: :working},
            started_at: started_at
          },
          issue_paused.id => %{
            pid: pid_paused,
            ref: nil,
            identifier: issue_paused.identifier,
            issue: issue_paused,
            control: %{status: :paused},
            started_at: started_at
          }
        },
        claimed: MapSet.new([issue_a.id, issue_b.id, issue_paused.id]),
        retry_attempts: %{issue_a.id => %{attempt: 1}, issue_b.id => %{attempt: 1}}
      }

      try do
        next =
          PushRouting.maybe_notify_agents_on_default_branch_push(state, "main", %{
            sha: "abc123"
          })

        # No agent is terminated — the kill-on-merge fleet thrash is gone. Each
        # agent is notified via its own system.<base>.branch.push subscription and
        # keeps its in-flight turn.
        assert Map.has_key?(next.running, issue_a.id)
        assert Map.has_key?(next.running, issue_b.id)
        assert Map.has_key?(next.running, issue_paused.id)

        # Claims and retry bookkeeping survive — nothing is released or
        # re-dispatched.
        assert MapSet.member?(next.claimed, issue_a.id)
        assert MapSet.member?(next.claimed, issue_b.id)
        assert MapSet.member?(next.claimed, issue_paused.id)
        assert Map.has_key?(next.retry_attempts, issue_a.id)
        assert Map.has_key?(next.retry_attempts, issue_b.id)

        # The agent tasks are still alive (no brutal kill).
        assert Process.alive?(pid_a)
        assert Process.alive?(pid_b)
        assert Process.alive?(pid_paused)
      after
        Process.exit(pid_a, :kill)
        Process.exit(pid_b, :kill)
        Process.exit(pid_paused, :kill)
      end
    end

    test "non-default system branch push leaves active agents running" do
      issue = %Issue{id: "issue-feature", identifier: "563", state: "in-progress"}
      pid = spawn(fn -> Process.sleep(:infinity) end)
      started_at = DateTime.utc_now()

      state = %Orchestrator.State{
        running: %{
          issue.id => %{
            pid: pid,
            ref: nil,
            identifier: issue.identifier,
            issue: issue,
            control: %{status: :working},
            started_at: started_at
          }
        },
        claimed: MapSet.new([issue.id]),
        retry_attempts: %{}
      }

      next = PushRouting.maybe_notify_agents_on_default_branch_push(state, "release", %{sha: "def456"})

      assert Map.has_key?(next.running, issue.id)
      assert MapSet.member?(next.claimed, issue.id)
      assert Process.alive?(pid)

      Process.exit(pid, :kill)
    end

    test "configured non-main base branch is recognized and still non-destructive" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_base_branch: "trunk")

      issue = %Issue{id: "issue-trunk", identifier: "564", state: "in-progress"}
      pid = spawn(fn -> Process.sleep(:infinity) end)
      started_at = DateTime.utc_now()

      try do
        state = %Orchestrator.State{
          running: %{
            issue.id => %{
              pid: pid,
              ref: nil,
              identifier: issue.identifier,
              issue: issue,
              control: %{status: :working},
              started_at: started_at
            }
          },
          claimed: MapSet.new([issue.id]),
          retry_attempts: %{issue.id => %{attempt: 1}}
        }

        # The configured base branch (trunk) is the branch this reaction keys
        # on, but the notify-only behavior never terminates the agent.
        after_trunk =
          PushRouting.maybe_notify_agents_on_default_branch_push(state, "trunk", %{sha: "trunk123"})

        assert Map.has_key?(after_trunk.running, issue.id)
        assert MapSet.member?(after_trunk.claimed, issue.id)
        assert Map.has_key?(after_trunk.retry_attempts, issue.id)
        assert Process.alive?(pid)
      after
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end
    end
  end

  describe "PR-anchored comment routing (U4)" do
    setup do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-pr-anchored-route-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(test_root)
      on_exit(fn -> File.rm_rf(test_root) end)
      {:ok, test_root: test_root}
    end

    test "routes an open human PR (non-aiur head) PR-anchored, with NO agent:* label flip", %{
      test_root: test_root
    } do
      enable_pr_watch!(test_root)
      test_pid = self()

      # A PR fetch returning an OPEN PR on a human branch. The capture fun
      # records the synthetic unit instead of spawning a real agent.
      event = %{
        topic: "ticket.77.pr.review_comment",
        author_trusted?: true,
        open_pull_request_fetcher: fn 77 ->
          {:ok, %{"number" => 77, "state" => "open", "title" => "Add login", "body" => "please review", "head" => %{"ref" => "feature/login"}}}
        end,
        pr_anchored_dispatch_fun: fn state, issue ->
          send(test_pid, {:pr_anchored_dispatched, issue})
          state
        end
      }

      {:noreply, _next} = Orchestrator.handle_info({:event, event}, empty_orchestrator_state())

      assert_receive {:pr_anchored_dispatched, %Issue{} = unit}

      # Identity: keyed by PR number (resume key + comment topic), NOT a tracker id.
      assert unit.identifier == "77"
      assert unit.id == "pr-77"
      assert unit.pr_head_ref == "feature/login"
      assert unit.branch_name == "feature/login"
      assert unit.title == "Add login"

      # Safety: a synthetic PR unit carries no agent:* label — the human PR is
      # never mutated.
      assert unit.labels == []
      refute Enum.any?(unit.labels, &String.starts_with?(&1, "agent:"))
    end

    test "an UNTRUSTED commenter on an open human PR is refused PR-anchored dispatch", %{
      test_root: test_root
    } do
      enable_pr_watch!(test_root)
      test_pid = self()
      fetcher_calls = capture_fetcher(test_pid)

      # Same open-human-PR setup as the happy path, but the comment author is NOT
      # trusted. Third-party comments must never wake a PR-anchored agent (the
      # agent treats the comment body as instructions and can push to the branch).
      # The trust gate short-circuits at routing time: no PR-anchored dispatch and
      # not even a `GET /pulls/N` fetch — the comment falls through to legacy.
      event = %{
        topic: "ticket.77.pr.review_comment",
        author_trusted?: false,
        open_pull_request_fetcher:
          fetcher_calls.(fn 77 ->
            {:ok, %{"number" => 77, "state" => "open", "head" => %{"ref" => "feature/login"}}}
          end),
        pr_anchored_dispatch_fun: fn state, issue ->
          send(test_pid, {:pr_anchored_dispatched, issue})
          state
        end
      }

      {:noreply, _next} = Orchestrator.handle_info({:event, event}, empty_orchestrator_state())

      refute_received {:pr_anchored_dispatched, _unit}
      refute_received {:fetcher_called, _pr_number}
    end

    test "a 404 (plain issue) falls through to the legacy path, never PR-anchored", %{
      test_root: test_root
    } do
      enable_pr_watch!(test_root)
      test_pid = self()
      fetcher_calls = capture_fetcher(test_pid)

      # `/pulls/N` 404 → {:ok, nil}: N is a plain tracker issue. Trusted author so
      # routing reaches the fetch; the nil result then falls through to legacy.
      event = %{
        topic: "ticket.55.pr.review_comment",
        author_trusted?: true,
        open_pull_request_fetcher: fetcher_calls.(fn 55 -> {:ok, nil} end),
        pr_anchored_dispatch_fun: fn state, issue ->
          send(test_pid, {:pr_anchored_dispatched, issue})
          state
        end
      }

      {:noreply, _next} = Orchestrator.handle_info({:event, event}, empty_orchestrator_state())

      assert_receive {:fetcher_called, 55}
      refute_received {:pr_anchored_dispatched, _unit}
    end

    test "an aiur/<N>-headed PR (legacy aiur PR) falls through to the legacy path", %{
      test_root: test_root
    } do
      enable_pr_watch!(test_root)
      test_pid = self()

      # An OPEN PR whose head is aiur/<N> is a LEGACY aiur PR; its comments must
      # keep flowing through the unchanged reactivation, never PR-anchored.
      event = %{
        topic: "ticket.42.pr.review_comment",
        author_trusted?: true,
        open_pull_request_fetcher: fn 42 ->
          {:ok, %{"number" => 42, "state" => "open", "head" => %{"ref" => "aiur/42"}}}
        end,
        pr_anchored_dispatch_fun: fn state, issue ->
          send(test_pid, {:pr_anchored_dispatched, issue})
          state
        end
      }

      {:noreply, _next} = Orchestrator.handle_info({:event, event}, empty_orchestrator_state())

      refute_received {:pr_anchored_dispatched, _unit}
    end

    test "feature off bypasses routing entirely — no /pulls/N fetch", %{test_root: test_root} do
      # pr_watch disabled (default): the legacy path runs and the PR fetcher is
      # NEVER called (zero new GitHub requests).
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "acme/widgets",
        workspace_root: test_root
      )

      test_pid = self()

      event = %{
        topic: "ticket.99.pr.review_comment",
        author_trusted?: true,
        open_pull_request_fetcher: fn _n ->
          send(test_pid, :fetcher_called)
          {:ok, nil}
        end,
        pr_anchored_dispatch_fun: fn state, issue ->
          send(test_pid, {:pr_anchored_dispatched, issue})
          state
        end
      }

      {:noreply, _next} = Orchestrator.handle_info({:event, event}, empty_orchestrator_state())

      refute_received :fetcher_called
      refute_received {:pr_anchored_dispatched, _unit}
    end

    test "a follow-up comment on a running PR-anchored agent resumes (no re-dispatch)", %{
      test_root: test_root
    } do
      enable_pr_watch!(test_root)
      test_pid = self()

      # A PR-anchored agent is already running, keyed by identifier == "77".
      state =
        empty_orchestrator_state()
        |> Map.put(:running, %{
          "pr-77" => %{
            pid: nil,
            ref: nil,
            identifier: "77",
            issue: %Issue{id: "pr-77", identifier: "77", state: "pr-watch", pr_head_ref: "feature/login"},
            started_at: DateTime.utc_now(),
            control: %{status: :working}
          }
        })

      event = %{
        topic: "ticket.77.pr.review_comment",
        author_trusted?: true,
        open_pull_request_fetcher: fn _n ->
          send(test_pid, :fetcher_called)
          {:ok, %{"number" => 77, "state" => "open", "head" => %{"ref" => "feature/login"}}}
        end,
        pr_anchored_dispatch_fun: fn s, issue ->
          send(test_pid, {:pr_anchored_dispatched, issue})
          s
        end
      }

      {:noreply, _next} = Orchestrator.handle_info({:event, event}, state)

      # Resolved to the EXISTING running entry: no fresh PR resolution, no
      # re-dispatch (the live agent sees the comment via its own subscription).
      refute_received :fetcher_called
      refute_received {:pr_anchored_dispatched, _unit}
    end
  end

  describe "PR-anchored lifecycle teardown (U6)" do
    setup do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "aiur-pr-anchored-teardown-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(test_root)
      on_exit(fn -> File.rm_rf(test_root) end)
      {:ok, test_root: test_root}
    end

    test "a PR-anchored agent whose PR closed/merged is terminated and its pr-<pr#> workspace cleaned",
         %{test_root: test_root} do
      enable_pr_watch!(test_root)

      # The PR-anchored workspace lives at the `pr-<pr#>` leaf (namespaced by
      # repo), NOT the bare `<pr#>` leaf. Create it so we can prove teardown
      # removes the correct directory.
      pr_workspace = Path.join([test_root, "acme", "widgets", "pr-77"])
      File.mkdir_p!(pr_workspace)

      agent_pid = spawn(fn -> Process.sleep(:infinity) end)
      ref = Process.monitor(agent_pid)

      state = pr_anchored_running_state(77, agent_pid)

      next =
        PrAnchored.maybe_stop_closed_pr_anchored_agents(state,
          # {:ok, nil} == closed/merged/missing PR.
          open_pull_request_fetcher: fn "77" -> {:ok, nil} end
        )

      # Running entry, claim, and retry_attempts all torn down.
      refute Map.has_key?(next.running, "pr-77")
      refute MapSet.member?(next.claimed, "pr-77")
      refute Map.has_key?(next.retry_attempts, "pr-77")

      # Agent task was killed.
      assert_receive {:DOWN, ^ref, :process, ^agent_pid, :killed}, 500

      # The pr-<pr#> workspace is gone — no orphan left behind.
      refute File.exists?(pr_workspace)
    end

    test "a PR-anchored agent whose PR closed clears its persisted resume handle",
         %{test_root: test_root} do
      enable_pr_watch!(test_root)

      # claude-repl is resumable (#613): without clearing on a closed PR, a
      # reopened PR would `--resume` the finished thread. The handle is keyed by
      # the PR-number identifier the agent session persisted under (here "77"),
      # not the `pr-77` running-map key.
      :ok = SessionHandle.save("77", %{backend: "claude-repl", thread_id: "session-xyz"})
      assert {:ok, %{thread_id: "session-xyz"}} = SessionHandle.load("77", "claude-repl")

      agent_pid = spawn(fn -> Process.sleep(:infinity) end)
      state = pr_anchored_running_state(77, agent_pid)

      PrAnchored.maybe_stop_closed_pr_anchored_agents(state,
        # {:ok, nil} == closed/merged/missing PR.
        open_pull_request_fetcher: fn "77" -> {:ok, nil} end
      )

      # The closed-PR teardown is terminal for this unit, so the handle is gone.
      assert :none == SessionHandle.load("77", "claude-repl")
    end

    test "a PR-anchored agent whose PR is still open is NOT terminated", %{test_root: test_root} do
      enable_pr_watch!(test_root)

      agent_pid = spawn(fn -> Process.sleep(:infinity) end)
      state = pr_anchored_running_state(77, agent_pid)

      next =
        PrAnchored.maybe_stop_closed_pr_anchored_agents(state,
          open_pull_request_fetcher: fn "77" ->
            {:ok, %{"number" => 77, "state" => "open", "head" => %{"ref" => "feature/login"}}}
          end
        )

      assert Map.has_key?(next.running, "pr-77")
      assert MapSet.member?(next.claimed, "pr-77")
      assert Process.alive?(agent_pid)

      Process.exit(agent_pid, :kill)
    end

    test "a fetch error does NOT terminate (transient-safe)", %{test_root: test_root} do
      enable_pr_watch!(test_root)

      agent_pid = spawn(fn -> Process.sleep(:infinity) end)
      state = pr_anchored_running_state(77, agent_pid)

      next =
        PrAnchored.maybe_stop_closed_pr_anchored_agents(state,
          open_pull_request_fetcher: fn "77" -> {:error, :rate_limited} end
        )

      assert Map.has_key?(next.running, "pr-77")
      assert Process.alive?(agent_pid)

      Process.exit(agent_pid, :kill)
    end

    test "feature off issues no fetch and terminates nothing", %{test_root: test_root} do
      # pr_watch disabled (default): no fetch, no teardown.
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "acme/widgets",
        workspace_root: test_root
      )

      test_pid = self()
      agent_pid = spawn(fn -> Process.sleep(:infinity) end)
      state = pr_anchored_running_state(77, agent_pid)

      next =
        PrAnchored.maybe_stop_closed_pr_anchored_agents(state,
          open_pull_request_fetcher: fn _pr ->
            send(test_pid, :fetcher_called)
            {:ok, nil}
          end
        )

      refute_received :fetcher_called
      assert Map.has_key?(next.running, "pr-77")
      assert Process.alive?(agent_pid)

      Process.exit(agent_pid, :kill)
    end

    test "no PR-anchored running entries issues no fetch (legacy entries are skipped)", %{
      test_root: test_root
    } do
      enable_pr_watch!(test_root)

      test_pid = self()
      agent_pid = spawn(fn -> Process.sleep(:infinity) end)

      # A legacy tracker-issue running entry (state != @pr_anchored_state) must
      # never be selected for PR-anchored teardown — and with zero PR-anchored
      # entries, no fetch is issued at all.
      state = %Orchestrator.State{
        running: %{
          "issue-1" => %{
            pid: agent_pid,
            ref: nil,
            identifier: "501",
            issue: %Issue{id: "issue-1", identifier: "501", state: "in-progress"},
            started_at: DateTime.utc_now(),
            control: %{status: :working}
          }
        },
        claimed: MapSet.new(["issue-1"]),
        retry_attempts: %{}
      }

      next =
        PrAnchored.maybe_stop_closed_pr_anchored_agents(state,
          open_pull_request_fetcher: fn _pr ->
            send(test_pid, :fetcher_called)
            {:ok, nil}
          end
        )

      refute_received :fetcher_called
      assert Map.has_key?(next.running, "issue-1")
      assert Process.alive?(agent_pid)

      Process.exit(agent_pid, :kill)
    end
  end

  defp pr_anchored_running_state(pr_number, agent_pid) do
    key = "pr-#{pr_number}"
    identifier = to_string(pr_number)

    %Orchestrator.State{
      running: %{
        key => %{
          pid: agent_pid,
          ref: nil,
          identifier: identifier,
          issue: %Issue{
            id: key,
            identifier: identifier,
            state: "pr-watch",
            pr_head_ref: "feature/login"
          },
          started_at: DateTime.utc_now(),
          control: %{status: :working}
        }
      },
      claimed: MapSet.new([key]),
      retry_attempts: %{key => %{attempt: 1}}
    }
  end

  defp enable_pr_watch!(test_root) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "acme/widgets",
      workspace_root: test_root,
      pr_watch_enabled: true
    )
  end

  defp capture_fetcher(test_pid) do
    fn inner ->
      fn pr_number ->
        send(test_pid, {:fetcher_called, pr_number})
        inner.(pr_number)
      end
    end
  end

  defp empty_orchestrator_state do
    %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{},
      max_concurrent_agents: 6
    }
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, value), do: Application.put_env(:aiur, key, value)

  defp human_review_running_state(issue_id, agent_pid) do
    %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: issue_id,
          issue: %Issue{
            id: issue_id,
            state: "in-progress",
            identifier: issue_id,
            tracker_identity: tracker_identity(issue_id)
          },
          started_at: DateTime.utc_now(),
          control: confirmed_control(:working)
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end

  defp control_test_agent(test_pid) do
    spawn(fn -> control_test_agent_loop(test_pid) end)
  end

  defp confirmed_control(status) do
    %{
      status: status,
      application_confirmation: :confirmed,
      generation: 101,
      version: 0
    }
  end

  defp tracker_identity(identifier) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "its-everdred",
      repository: "aiur",
      provider_id: "I_kwDO#{identifier}",
      identifier: "101",
      reason: nil
    }
  end

  # Models a long-lived agent process: it forwards each control message to the
  # test and stays alive, so a paused runner (CI-wait) remains alive exactly as
  # a real agent would rather than exiting after one message.
  defp control_test_agent_loop(test_pid) do
    receive do
      message ->
        send(test_pid, {:ci_wait_control, message})
        control_test_agent_loop(test_pid)
    end
  end

  defp human_review_issue(issue_id) do
    %Issue{
      id: issue_id,
      identifier: issue_id,
      state: "human-review",
      title: "PR up for review",
      description: "",
      labels: []
    }
  end

  defp datetime!(iso8601) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(iso8601)
    datetime
  end

  defp drain_issue_comment_requests(acc) do
    receive do
      {:issue_comments_requested, id} -> drain_issue_comment_requests([id | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  # Override the running CodeOwners allowlist so `Sanitizer.stamp_author_trust/2`
  # treats `logins` as trusted for the duration of a command-scan test, then
  # restore the previous allowlist in the `after` block. Mirrors the
  # github_comments_poller test's `ensure_codeowners!` pattern.
  defp trust_authors!(logins) do
    pid = Process.whereis(CodeOwners)
    previous = CodeOwners.snapshot(pid)
    Process.put(:command_scan_codeowners, %{pid: pid, previous: previous})
    allowlist = MapSet.new(Enum.map(logins, &String.downcase/1))
    :sys.replace_state(pid, fn state -> %{state | allowlist: allowlist} end)
    %{pid: pid, previous: previous}
  end

  defp codeowners_state, do: Process.get(:command_scan_codeowners)

  defp restore_trust!(nil), do: :ok

  defp restore_trust!(%{pid: pid, previous: previous}) do
    if Process.alive?(pid) do
      :sys.replace_state(pid, &%{&1 | allowlist: MapSet.new(previous)})
    end

    Process.delete(:command_scan_codeowners)
    :ok
  end

  defp empty_review_threads_response do
    review_threads_response([])
  end

  defp review_threads_response(nodes) do
    {:ok,
     %{
       status: 200,
       body: %{
         "data" => %{
           "repository" => %{
             "pullRequest" => %{
               "reviewThreads" => %{
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                 "nodes" => nodes
               }
             }
           }
         }
       }
     }}
  end

  defp review_thread_comment(id, login, body) do
    %{
      "databaseId" => id,
      "body" => body,
      "author" => %{"login" => login},
      "createdAt" => "2026-06-24T12:00:00Z",
      "updatedAt" => "2026-06-24T12:00:00Z"
    }
  end
end

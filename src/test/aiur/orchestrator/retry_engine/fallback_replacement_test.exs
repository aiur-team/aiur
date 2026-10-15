defmodule Aiur.Orchestrator.RetryEngine.FallbackReplacementTest do
  use Aiur.TestSupport

  alias Aiur.AgentQueue
  alias Aiur.AgentQueueStore
  alias Aiur.AgentRunner.SessionLifecycle
  alias Aiur.CodingAgent
  alias Aiur.Issue
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.RateLimitFallback
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State

  describe "fallback replacement failures" do
    test "bare claude fallback does not inherit a codex routing model" do
      workflow_file = Application.fetch_env!(:aiur, :workflow_file_path)
      write_workflow_file!(workflow_file, agent_routing: %{3 => "codex:terra:high"})

      fallback_issue = %Issue{id: "fallback-model", identifier: "repo#fallback-model", labels: ["complexity:3", "model:claude"]}

      assert CodingAgent.backend_for(fallback_issue) == "claude"
      assert CodingAgent.model_for(fallback_issue) == nil
      refute CodingAgent.resolve_model("claude", CodingAgent.model_for(fallback_issue)) == "terra"

      {"claude", false, session_opts} = SessionLifecycle.resolve_session_options(fallback_issue, [], nil)
      refute Keyword.fetch!(session_opts, :model) == "terra"

      assert {:ok, %{model: launched_model}} =
               SessionLifecycle.start_agent_session(
                 "/workspace",
                 session_opts,
                 fn _workspace, opts -> {:ok, %{model: Keyword.fetch!(opts, :model)}} end
               )

      refute launched_model == "terra"
    end

    test "fallback redispatch dispatches bare claude with its current fence" do
      workflow_file = Application.fetch_env!(:aiur, :workflow_file_path)
      write_workflow_file!(workflow_file, agent_routing: %{3 => "codex:terra:high"})

      parent = self()

      fence = %{
        generation: 7,
        authoritative_state: "rework",
        pending_item_ids: MapSet.new([872, 874, 887, 891]),
        opened_at: DateTime.utc_now()
      }

      issue = %Issue{
        id: "fallback-redispatch",
        identifier: "repo#fallback-redispatch",
        labels: ["complexity:3"],
        selected_backend: "codex"
      }

      state = %State{
        max_concurrent_agents: 1,
        effective_concurrent_agents: 1,
        claimed: MapSet.new([issue.id]),
        running: %{
          issue.id => %{
            issue: issue,
            identifier: issue.identifier,
            worker_host: nil,
            control: %{status: :paused},
            paused_reason: :usage_limit_exhausted,
            lifecycle_fence: fence,
            workspace_path: "/workspaces/fallback-redispatch",
            started_at: DateTime.add(DateTime.utc_now(), -3_600, :second)
          }
        }
      }

      result =
        RateLimitFallback.reconcile(
          state,
          fallback_backend: "claude",
          primary_backend: "codex",
          current_backend: "codex",
          state: %{"backends" => %{"codex" => %{limited: false}}},
          backend_ready_fun: fn _backend, _worker_host -> true end,
          dispatch_ready_fun: fn _state, _issue, _worker_host -> :ok end,
          add_label_fun: fn _identifier, _label -> :ok end,
          teardown_fun: fn current_state, _entry, _reason -> current_state end,
          dispatch_fun: fn current_state, fallback_issue, attempt, worker_host ->
            Dispatcher.do_dispatch_issue(
              current_state,
              fallback_issue,
              attempt,
              worker_host,
              runner: fn launched_issue, _recipient, _opts ->
                launched_model = CodingAgent.model_for(launched_issue)
                send(parent, {:fallback_dispatch_started, launched_model})
                :ok
              end
            )
          end
        )

      replacement = result.running[issue.id]

      assert replacement.lifecycle_fence == fence
      assert replacement.workspace_path == "/workspaces/fallback-redispatch"
      assert replacement.issue.selected_backend == "claude"
      assert is_pid(replacement.pid)
      assert_receive {:fallback_dispatch_started, launched_model}, 1_000
      refute launched_model == "terra"
    end

    test "completed fallback exits before redispatching to the recovered primary" do
      parent = self()
      issue_id = "fallback-completed"

      fallback_issue = %Issue{
        id: issue_id,
        identifier: "repo#fallback-completed",
        title: "Fallback completed",
        state: "in-progress",
        labels: ["model:claude", "agent:rate-limit-fallback"],
        selected_backend: "claude"
      }

      ref = make_ref()

      state = %State{
        max_concurrent_agents: 1,
        effective_concurrent_agents: 1,
        claimed: MapSet.new([issue_id]),
        running: %{
          issue_id => %{
            ref: ref,
            pid: self(),
            issue: fallback_issue,
            identifier: fallback_issue.identifier,
            started_at: DateTime.utc_now(),
            control: %{status: :completed},
            completed_turn_count: 1,
            redispatch_safety: %{workspace_path: "/workspaces/fallback-completed"},
            rate_limit_fallback_replacement: true
          }
        }
      }

      assert {:noreply, exited_state} = RetryEngine.handle_agent_down(state, ref, :normal)
      assert %{pid: nil, ref: nil} = exited_state.running[issue_id]
      refute Map.has_key?(exited_state.running[issue_id], :rate_limit_fallback_replacement)

      recovered_primary_issue = %Issue{
        id: issue_id,
        identifier: fallback_issue.identifier,
        title: fallback_issue.title,
        state: "In Progress"
      }

      assert Orchestrator.retry_candidate_issue?(recovered_primary_issue, MapSet.new(["done"]))
      assert Slots.dispatch_slots_available?(recovered_primary_issue, exited_state)
      assert Slots.worker_slots_available?(exited_state, nil)

      assert {:noreply, redispatched_state} =
               RetryEngine.handle_retry_issue_lookup(
                 recovered_primary_issue,
                 exited_state,
                 issue_id,
                 1,
                 %{worker_host: nil, prior_work: true},
                 terminal_states: MapSet.new(["done"]),
                 dispatch_fun: fn current_state, ^recovered_primary_issue, 1, nil, _dispatch_opts ->
                   send(parent, {:redispatched_backend, CodingAgent.backend_for(recovered_primary_issue)})

                   put_in(current_state.running[issue_id], %{
                     pid: parent,
                     issue: recovered_primary_issue
                   })
                 end
               )

      assert_receive {:redispatched_backend, "codex"}, 1000
      refute Map.has_key?(redispatched_state.running[issue_id], :rate_limit_fallback_replacement)
    end

    test "park the fence and restore its failed authoritative item for retry" do
      issue = %Issue{id: "fallback-startup", identifier: "repo#fallback", state: "in-progress"}
      fence = %{generation: 7, authoritative_state: "rework", pending_item_ids: MapSet.new([1]), opened_at: DateTime.utc_now()}
      {queue_store, item} = AgentQueue.operator_message(issue.identifier, "do not lose this") |> then(&AgentQueueStore.enqueue(AgentQueueStore.new(), &1))
      {queue_store, _claimed} = AgentQueueStore.claim_next_deliverable(queue_store, issue.identifier)
      {queue_store, _failed} = AgentQueueStore.mark_failed(queue_store, item.id, :unsupported_model)
      ref = make_ref()

      state = %State{
        queue_store: queue_store,
        running: %{
          issue.id => %{
            ref: ref,
            pid: self(),
            issue: issue,
            identifier: issue.identifier,
            started_at: DateTime.utc_now(),
            control: %{status: :working},
            lifecycle_fence: fence,
            redispatch_safety: %{workspace_path: "/workspaces/fallback"},
            rate_limit_fallback_replacement: true
          }
        },
        claimed: MapSet.new([issue.id])
      }

      # A runner reports its startup error as a normal Task exit after it has
      # already failed the claimed queue item. This is the production shape of
      # an unsupported fallback model.
      assert {:noreply, next_state} = RetryEngine.handle_agent_down(state, ref, :normal)
      assert next_state.queue_store.items[item.id].status == :pending
      assert next_state.running[issue.id].lifecycle_fence == fence
      assert next_state.running[issue.id].control.status == :completed
      assert Map.has_key?(next_state.retry_attempts, issue.id)
      assert MapSet.member?(next_state.claimed, issue.id)
    end
  end
end

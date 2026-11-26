defmodule Aiur.Orchestrator.Dispatcher.CommandGateTest do
  use Aiur.DispatcherTestSupport

  alias Aiur.Orchestrator.TokenAccounting

  describe "blocking Command dispatch gate (#1965)" do
    test "an expired unanswered blocking Command no longer gates dispatch" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 4)
      candidate = issue("decision-cycle-#{System.unique_integer([:positive])}")

      ticket = %{identifier: candidate.id, title: candidate.title, url: candidate.url}

      source = %{
        agent_id: "dispatcher-test",
        session_id: "session-#{candidate.id}",
        event_id: nil
      }

      assert {:ok, %{decision: decision}} =
               Aiur.DecisionStore.request(
                 %{"question" => "Which path should this ticket take?", "blocking" => true},
                 ticket: ticket,
                 source: source
               )

      on_exit(fn ->
        Aiur.DecisionStore.answer(
          decision.decision_id,
          %{
            "idempotency_key" => "cleanup-#{decision.decision_id}",
            "expected_version" => decision.version,
            "custom_response" => "Proceed"
          },
          actor: %{kind: :operator, id: "dispatcher-test"}
        )
      end)

      state =
        %State{max_concurrent_agents: 4, effective_concurrent_agents: 4}
        |> Dispatcher.refresh_blocked_ticket_ids()

      assert Dispatcher.choose_issues(state, [candidate]).dispatch_declines[candidate.id] == :blocked_on_decision

      assert {:ok, %{status: :accepted, decision: expired}} = Aiur.DecisionStore.expire(decision.decision_id, "agent_not_running")
      assert expired.decision_status == :expired
      expired_state = Dispatcher.refresh_blocked_ticket_ids(state)
      assert Dispatcher.choose_issues(expired_state, [candidate]).dispatch_declines[candidate.id] == :tracker_revalidation_failed

      assert {:ok, %{status: :accepted}} =
               Aiur.DecisionStore.answer(
                 decision.decision_id,
                 %{
                   "idempotency_key" => "release-#{decision.decision_id}",
                   "expected_version" => decision.version,
                   "custom_response" => "Proceed"
                 },
                 actor: %{kind: :operator, id: "dispatcher-test"}
               )

      next_state = Dispatcher.refresh_blocked_ticket_ids(expired_state)

      assert DispatchPolicy.dispatch_decision(
               candidate,
               next_state,
               DispatchPolicy.active_state_set(),
               DispatchPolicy.terminal_state_set(),
               next_state.blocked_ticket_ids
             ) == :dispatch
    end

    test "an answered absent worker releases a stale decision hold within one poll (#3516)" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 4, tracker_active_states: ["todo", "in-progress"])
      restore_workflow_file_after_test()
      test_pid = self()
      ticket_id = "answer-resume-#{System.unique_integer([:positive])}"
      candidate = %Issue{id: ticket_id, identifier: ticket_id, title: ticket_id, state: "in-progress", selected_backend: "codex"}

      # The fake dispatcher refuses delivery until the runner starts a worker.
      worker = start_supervised!({Agent, fn -> false end})

      dispatcher = fn decision, _opts ->
        if Agent.get(worker, & &1) do
          send(test_pid, {:worker_received, decision.decision_id, decision.active_action_id, decision.answer.selected_option_id})
          {:ok, %{status: :accepted, item: %{id: System.unique_integer([:positive])}}}
        else
          send(test_pid, {:no_worker, decision.decision_id})
          {:error, :no_running_agent}
        end
      end

      dir = Aiur.TestSupport.tmp_root!("dispatcher-answer-resume")

      store =
        start_supervised!(
          {Aiur.DecisionStore,
           [
             name: nil,
             state_dir: dir,
             filesystem_sync_fun: fn -> :ok end,
             dispatcher: dispatcher,
             dispatch_delay_ms: 0,
             retry_delays_ms: [0, 0, 0]
           ]},
          id: :dispatcher_answer_resume_store
        )

      poll = fn state ->
        Dispatcher.dispatch_or_hold(state, [candidate], fn -> :ready end,
          admission_probes_fun: contended_probes(0, nil),
          issue_fetcher: fn [id] -> {:ok, [%{candidate | id: id}]} end,
          blocked_by_hydrator: fn refreshed -> {:ok, refreshed} end,
          runner: fn dispatched, _recipient, _opts ->
            Agent.update(worker, fn _running -> true end)
            send(test_pid, {:agent_runner_run, dispatched.id})
          end,
          decision_store: store
        )
      end

      assert {:ok, %{decision: decision}} =
               Aiur.DecisionStore.request(
                 %{
                   "question" => "Which path should this ticket take?",
                   "blocking" => true,
                   "options" => [%{"id" => "a", "label" => "Path A"}, %{"id" => "b", "label" => "Path B"}]
                 },
                 [ticket: %{identifier: ticket_id, title: ticket_id, url: nil}, source: %{agent_id: "dispatcher-test", session_id: "s-1", event_id: nil}],
                 store
               )

      id = decision.decision_id

      assert {:ok, cached_holds} = Aiur.DecisionStore.blocked_ticket_ids(store)
      held = poll.(%State{max_concurrent_agents: 4, effective_concurrent_agents: 4, blocked_ticket_ids: cached_holds})
      assert held.dispatch_declines[ticket_id] == :blocked_on_decision
      refute Map.has_key?(held.running, ticket_id)

      assert {:ok, %{status: :accepted}} =
               Aiur.DecisionStore.answer(
                 id,
                 %{"idempotency_key" => "resume-#{id}", "expected_version" => decision.version, "option_id" => "b"},
                 [actor: %{kind: :operator, id: "dispatcher-test"}, now: DateTime.add(DateTime.utc_now(), 60, :second)],
                 store
               )

      assert_receive {:no_worker, ^id}, 1_000
      refute_receive {:no_worker, ^id}, 100

      resumed = poll.(held)
      assert_receive {:agent_runner_run, ^ticket_id}, 1_000
      assert Map.has_key?(resumed.running, ticket_id)
      refute Map.has_key?(resumed.dispatch_declines, ticket_id)
      refute MapSet.member?(resumed.blocked_ticket_ids, ticket_id)

      assert_received {:deliver_pending_answers, ^ticket_id, ^store} = message
      refute_received {:no_worker, ^id}
      assert :ok = Dispatcher.handle_pending_answer_delivery(message)
      assert {:ok, %{delivery_status: :pending, pending_for_session?: true}} = Aiur.DecisionStore.get(id, store)
      refute_receive {:worker_received, ^id, _, _}, 300
    end

    test "a slow poll leaves an absent-agent answer pending until session start (#2713)" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 4)
      restore_workflow_file_after_test()
      test_pid = self()
      ticket_id = "answer-slow-poll-#{System.unique_integer([:positive])}"
      candidate = %Issue{id: ticket_id, identifier: ticket_id, title: ticket_id, state: "todo", selected_backend: "codex"}
      orchestrator = start_supervised!({SlowPollOrchestrator, self()})

      store =
        start_supervised!(
          {Aiur.DecisionStore,
           [
             name: nil,
             state_dir: Aiur.TestSupport.tmp_root!("dispatcher-answer-slow-poll"),
             filesystem_sync_fun: fn -> :ok end,
             dispatcher: fn _decision, _opts -> {:error, :no_running_agent} end,
             dispatch_delay_ms: 0,
             retry_delays_ms: []
           ]},
          id: :dispatcher_answer_slow_poll_store
        )

      assert {:ok, %{decision: decision}} =
               Aiur.DecisionStore.request(
                 %{"question" => "Which path should this ticket take?", "blocking" => true, "options" => [%{"id" => "a", "label" => "Path A"}, %{"id" => "b", "label" => "Path B"}]},
                 [ticket: %{identifier: ticket_id, title: ticket_id, url: nil}, source: %{agent_id: "dispatcher-test", session_id: "s-1", event_id: nil}],
                 store
               )

      assert {:ok, %{status: :accepted}} =
               Aiur.DecisionStore.answer(
                 decision.decision_id,
                 %{"idempotency_key" => "slow-#{decision.decision_id}", "expected_version" => decision.version, "option_id" => "a"},
                 [actor: %{kind: :operator, id: "dispatcher-test"}],
                 store
               )

      wait_until(fn -> match?({:ok, %{pending_for_session?: true}}, Aiur.DecisionStore.get(decision.decision_id, store)) end)
      assert {:ok, pending} = Aiur.DecisionStore.get(decision.decision_id, store)

      poll = fn ->
        state = %State{max_concurrent_agents: 4, effective_concurrent_agents: 4, blocked_ticket_ids: MapSet.new()}

        next =
          Dispatcher.choose_issues(state, [candidate],
            issue_fetcher: fn [ticket] -> {:ok, [%{candidate | id: ticket}]} end,
            blocked_by_hydrator: fn refreshed -> {:ok, refreshed} end,
            runner: fn _dispatched, _recipient, runner_opts -> send(test_pid, {:runner_options, runner_opts}) end,
            decision_store: store
          )

        next
      end

      next = GenServer.call(orchestrator, {:poll, poll, 800}, 5_000)
      assert_receive {:runner_options, runner_opts}, 1_000

      assert [%{action_id: action_id, question: "Which path should this ticket take?", answer: "a: Path A"}] =
               runner_opts[:answered_decisions]

      assert action_id == pending.active_action_id
      assert Map.has_key?(next.running, ticket_id)

      assert {:ok, %{delivery_status: :pending, pending_for_session?: true}} =
               Aiur.DecisionStore.get(decision.decision_id, store)

      started_at = DateTime.utc_now()
      running = next.running[ticket_id]
      {started, _delta} = TokenAccounting.integrate_codex_update(running, %{event: :session_started, timestamp: started_at, thread_id: "slow-poll-session"})
      next = %{next | running: Map.put(next.running, ticket_id, started)}

      {:noreply, _next} =
        TokenAccounting.handle_codex_worker_update(
          next,
          ticket_id,
          %{event: :notification, timestamp: started_at, payload: %{"method" => "turn/started"}}
        )

      wait_until(fn -> match?({:ok, %{pending_for_session?: false}}, Aiur.DecisionStore.get(decision.decision_id, store)) end)
    end

    test "a ticket with an open blocking Command is declined and the reason is visible in status" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 4)
      candidate = issue("blocked-command")
      :ok = AgentPubSub.subscribe_agent(candidate.identifier)

      state = %State{
        max_concurrent_agents: 4,
        effective_concurrent_agents: 4,
        blocked_ticket_ids: MapSet.new([candidate.id])
      }

      declined = Dispatcher.choose_issues(state, [candidate])

      assert declined.dispatch_declines[candidate.id] == :blocked_on_decision
      refute Map.has_key?(declined.running, candidate.id)
      refute MapSet.member?(declined.claimed, candidate.id)

      assert_receive {:alert,
                      %{
                        name: "dispatch.candidate_declined",
                        reason: reason,
                        needs_attention: false
                      }},
                     2_000

      assert reason =~ "blocked_on_decision"
    end

    test "an unreadable decision store fails closed (no new dispatch)" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 4)
      candidate = issue("store-unavailable")
      :ok = AgentPubSub.subscribe_agent(candidate.identifier)

      state = %State{
        max_concurrent_agents: 4,
        effective_concurrent_agents: 4,
        blocked_ticket_ids: :unavailable
      }

      declined = Dispatcher.choose_issues(state, [candidate])

      assert declined.dispatch_declines[candidate.id] == :blocked_on_decision
      refute Map.has_key?(declined.running, candidate.id)
      refute MapSet.member?(declined.claimed, candidate.id)
    end

    test "dispatch_issue refuses to spawn a fresh agent while a blocking Command is open" do
      candidate = issue("dispatch-issue-blocked")
      :ok = AgentPubSub.subscribe_agent(candidate.identifier)

      state = %State{effective_concurrent_agents: 4, blocked_ticket_ids: MapSet.new([candidate.id])}

      declined =
        Dispatcher.dispatch_issue(state, candidate, nil, nil,
          issue_fetcher: fn [id] -> {:ok, [%{candidate | id: id}]} end,
          blocked_by_hydrator: fn issue -> {:ok, issue} end
        )

      assert declined.dispatch_declines[candidate.id] == :blocked_on_decision
      refute Map.has_key?(declined.running, candidate.id)
      refute MapSet.member?(declined.claimed, candidate.id)
    end

    test "dispatch_issue proceeds when the ticket has no open blocking Command" do
      test_pid = self()
      candidate = %{issue("unblocked-dispatch") | selected_backend: "codex"}

      runner = fn dispatched, recipient, opts ->
        send(test_pid, {:agent_runner_run, dispatched, recipient, opts})
        :ok
      end

      state = %State{
        max_concurrent_agents: 4,
        effective_concurrent_agents: 4,
        blocked_ticket_ids: MapSet.new(["other"])
      }

      next_state =
        Dispatcher.dispatch_issue(state, candidate, nil, nil,
          issue_fetcher: fn [id] -> {:ok, [%{candidate | id: id}]} end,
          blocked_by_hydrator: fn refreshed -> {:ok, refreshed} end,
          runner: runner
        )

      assert_receive {:agent_runner_run, dispatched, _recipient, _opts}, 1000
      assert dispatched.id == candidate.id
      assert Map.has_key?(next_state.running, candidate.id)
    end
  end
end

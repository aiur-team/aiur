defmodule Aiur.Orchestrator.AnsweredDecisionsLaunchTest do
  use Aiur.TestSupport

  alias Aiur.{DecisionPubSub, DecisionStore, Issue}
  alias Aiur.Orchestrator.{Dispatcher, State, TokenAccounting, TrackerTasks}
  alias Aiur.TestSupport.Isolation

  setup do
    :ok = DecisionPubSub.subscribe()
    :ok
  end

  test "a pre-turn runner failure leaves the answer pending until the next turn starts", %{test: test} do
    parent = self()
    dir = Aiur.TestSupport.tmp_root!("answered-decisions-launch")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    store =
      start_supervised!(
        {DecisionStore,
         name: nil,
         state_dir: dir,
         filesystem_sync_fun: fn -> :ok end,
         dispatch_delay_ms: 0,
         retry_delays_ms: [],
         dispatcher: fn _decision, _opts -> {:error, :no_running_agent} end,
         answer_comment_publisher: fn _decision -> :ok end}
      )

    ticket = %{identifier: "5491", title: "Carry decisions", url: nil}
    source = %{agent_id: "agent-5491", session_id: "session-before", event_id: nil}

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{
                 "question" => "Which rollout?",
                 "blocking" => true,
                 "source_id" => "launch-#{test}",
                 "options" => [%{"id" => "ship", "label" => "Ship it"}]
               },
               [ticket: ticket, source: source],
               store
             )

    accepted_at = DateTime.add(DateTime.utc_now(), -3_600, :second)

    assert {:ok, _answer} =
             DecisionStore.answer(
               decision.decision_id,
               %{"idempotency_key" => "launch-answer", "expected_version" => 1, "custom_response" => "Proceed verbatim"},
               [actor: %{kind: :operator, id: "operator-1"}, now: accepted_at],
               store
             )

    pending = wait_for_decision(store, decision.decision_id, & &1.pending_for_session?)
    issue = %Issue{id: "5491", identifier: "5491", title: "Carry decisions", state: "todo", selected_backend: "codex"}

    state =
      Dispatcher.dispatch_issue(
        %State{snapshot_key: self(), max_concurrent_agents: 4, effective_concurrent_agents: 4},
        issue,
        nil,
        nil,
        decision_store: store,
        issue_fetcher: fn _ids -> {:ok, [issue]} end,
        blocked_by_hydrator: fn candidate -> {:ok, candidate} end,
        runner: fn _dispatched, _recipient, opts ->
          send(parent, {:runner_options, opts})
          exit(:workspace_setup_failed)
        end
      )
      |> apply_dispatch_result()

    assert_receive {:runner_options, opts}, 1_000
    assert [%{action_id: action_id, question: "Which rollout?", answer: "Proceed verbatim", actor: "operator: operator-1", accepted_at: ^accepted_at}] = opts[:answered_decisions]
    assert action_id == pending.active_action_id
    assert wait_for_decision(store, decision.decision_id, & &1.pending_for_session?).pending_for_session?
    assert Map.has_key?(state.running, issue.id)

    running = state.running[issue.id]
    {started, _delta} = TokenAccounting.integrate_codex_update(running, %{event: :session_started, timestamp: accepted_at, thread_id: "real-session-42"})
    next_state = %{state | running: Map.put(state.running, issue.id, started)}

    {:noreply, consumed_state} =
      TokenAccounting.handle_codex_worker_update(
        next_state,
        issue.id,
        %{event: :notification, timestamp: accepted_at, payload: %{"method" => "turn/started"}}
      )

    consumed = wait_for_decision(store, decision.decision_id, &(!&1.pending_for_session?))
    assert consumed.pending_for_session? == false
    assert {:ok, history} = DecisionStore.audit_history(decision.decision_id, store)
    assert %{type: :session_started, data: %{session_id: "real-session-42"}} = Enum.find(history, &(&1.type == :session_started))
    assert consumed_state.running[issue.id].native_session_id == "real-session-42"
  end

  test "dispatch continues with no decision store" do
    parent = self()
    issue = %Issue{id: "5491", identifier: "5491", title: "Carry decisions", state: "todo", selected_backend: "codex"}
    state = dispatch(issue, parent, :unregistered_decision_store)

    assert_receive {:runner_options, opts}, 1_000
    assert opts[:answered_decisions] == []
    assert Map.has_key?(state.running, issue.id)
  end

  test "dispatch continues when the decision store times out" do
    parent = self()

    slow_store =
      Isolation.start_owned!(
        {Task,
         fn ->
           receive do
             :stop -> :ok
           end
         end}
      )

    issue = %Issue{id: "5491", identifier: "5491", title: "Carry decisions", state: "todo", selected_backend: "codex"}
    state = dispatch(issue, parent, slow_store, decision_store_read_timeout: 10)

    assert_receive {:runner_options, opts}, 1_000
    assert opts[:answered_decisions] == []
    assert Map.has_key?(state.running, issue.id)
  end

  test "dispatch includes an answered decision whose prior delivery failed", %{test: test} do
    parent = self()
    dir = Aiur.TestSupport.tmp_root!("failed-answer-launch")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    store =
      start_supervised!(
        {DecisionStore,
         name: nil,
         state_dir: dir,
         filesystem_sync_fun: fn -> :ok end,
         dispatch_delay_ms: 0,
         retry_delays_ms: [],
         dispatcher: fn _decision, _opts -> {:error, :target_agent_unavailable} end,
         answer_comment_publisher: fn _decision -> :ok end}
      )

    ticket = %{identifier: "5491", title: "Carry decisions", url: nil}
    source = %{agent_id: "agent-5491", session_id: "session-before", event_id: nil}

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{
                 "question" => "Keep the failed answer?",
                 "blocking" => true,
                 "source_id" => "failed-#{test}",
                 "options" => [%{"id" => "keep", "label" => "Keep it"}]
               },
               [ticket: ticket, source: source],
               store
             )

    assert {:ok, _answer} =
             DecisionStore.answer(
               decision.decision_id,
               %{"idempotency_key" => "failed-answer", "expected_version" => 1, "custom_response" => "Retain this answer"},
               [actor: %{kind: :operator, id: "operator-1"}],
               store
             )

    failed = wait_for_decision(store, decision.decision_id, &(&1.delivery_status == :failed))
    refute failed.pending_for_session?

    issue = %Issue{id: "5491", identifier: "5491", title: "Carry decisions", state: "todo", selected_backend: "codex"}
    state = dispatch(issue, parent, store)

    assert_receive {:runner_options, opts}, 1_000
    assert [%{action_id: action_id, question: "Keep the failed answer?", answer: "Retain this answer"}] = opts[:answered_decisions]
    assert action_id == failed.active_action_id
    assert Map.has_key?(state.running, issue.id)
  end

  test "dispatch carries the active revision answer", %{test: test} do
    parent = self()
    dir = Aiur.TestSupport.tmp_root!("revised-answer-launch")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    store =
      start_supervised!(
        {DecisionStore,
         name: nil,
         state_dir: dir,
         filesystem_sync_fun: fn -> :ok end,
         dispatch_delay_ms: 0,
         retry_delays_ms: [],
         dispatcher: fn _decision, _opts -> {:error, :no_running_agent} end,
         answer_comment_publisher: fn _decision -> :ok end}
      )

    ticket = %{identifier: "5491", title: "Carry decisions", url: nil}
    source = %{agent_id: "agent-5491", session_id: "session-before", event_id: nil}

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{
                 "question" => "Which rollout?",
                 "blocking" => true,
                 "source_id" => "revision-#{test}",
                 "options" => [%{"id" => "ship", "label" => "Ship it"}, %{"id" => "hold", "label" => "Hold it"}]
               },
               [ticket: ticket, source: source],
               store
             )

    assert {:ok, %{action: first}} =
             DecisionStore.answer(
               decision.decision_id,
               %{"idempotency_key" => "revision-original", "expected_version" => 1, "option_id" => "ship"},
               [actor: %{kind: :operator, id: "operator-1"}],
               store
             )

    _pending = wait_for_decision(store, decision.decision_id, & &1.pending_for_session?)

    assert {:ok, %{action: revision}} =
             DecisionStore.revise(
               decision.decision_id,
               %{
                 "idempotency_key" => "revision-next",
                 "expected_version" => 1,
                 "expected_action_id" => first.action_id,
                 "expected_revision_sequence" => 0,
                 "option_id" => "hold",
                 "rationale" => "Hold for the next session."
               },
               [actor: %{kind: :operator, id: "operator-1"}],
               store
             )

    issue = %Issue{id: "5491", identifier: "5491", title: "Carry decisions", state: "todo", selected_backend: "codex"}
    state = dispatch(issue, parent, store)

    assert_receive {:runner_options, opts}, 1_000
    assert [%{action_id: action_id, answer: "hold: Hold it"}] = opts[:answered_decisions]
    assert action_id == revision.action_id
    assert Map.has_key?(state.running, issue.id)
  end

  defp dispatch(issue, parent, store, opts \\ []) do
    Dispatcher.dispatch_issue(
      %State{snapshot_key: self(), max_concurrent_agents: 4, effective_concurrent_agents: 4},
      issue,
      nil,
      nil,
      Keyword.merge(
        [
          decision_store: store,
          issue_fetcher: fn _ids -> {:ok, [issue]} end,
          blocked_by_hydrator: fn candidate -> {:ok, candidate} end,
          runner: fn _dispatched, _recipient, runner_opts -> send(parent, {:runner_options, runner_opts}) end
        ],
        opts
      )
    )
    |> apply_dispatch_result()
  end

  defp apply_dispatch_result(%State{} = state) do
    receive do
      {reference, result} when is_reference(reference) ->
        {:handled, dispatched} = TrackerTasks.result(state, reference, result)
        dispatched
    after
      1_000 -> flunk("dispatch validation did not finish")
    end
  end

  defp wait_for_decision(store, decision_id, predicate, attempts \\ 100)
  defp wait_for_decision(_store, _decision_id, _predicate, 0), do: flunk("decision did not reach expected state")

  defp wait_for_decision(store, decision_id, predicate, attempts) do
    {:ok, decision} = DecisionStore.get(decision_id, store)

    if predicate.(decision) do
      decision
    else
      assert_receive {:decision_changed, ^decision_id, _version}, 1_000
      wait_for_decision(store, decision_id, predicate, attempts - 1)
    end
  end
end

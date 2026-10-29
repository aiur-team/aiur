defmodule Aiur.DecisionOverrideLegacyDeliveryIntegrationTest do
  use Aiur.TestSupport

  alias Aiur.{DecisionDispatch, DecisionPubSub, DecisionStore, Issue, Orchestrator}
  alias Aiur.Orchestrator.{OperatorMessages, PauseResume}

  @identifier "6908"
  @actor %{kind: :operator, id: "human"}
  @source %{agent_id: "worker", session_id: "previous-session"}
  @context %{pr: %{number: 77, merged?: false}, worker: :resumable, capacity: :available}

  # Hosts the production callbacks with injected runner/transport ports. Running
  # entries and pause transitions are produced by Dispatcher and PauseResume.
  defmodule Runtime do
    use GenServer
    alias Aiur.Orchestrator.{Dispatcher, State}

    def start_link(_opts), do: GenServer.start_link(__MODULE__, [])

    @impl true
    def init(_opts) do
      Process.flag(:trap_exit, true)
      {:ok, %State{snapshot_key: self(), max_concurrent_agents: 2, effective_concurrent_agents: 2}}
    end

    @impl true
    def handle_call({:launch, issue, store, runner}, _from, state) do
      next = Dispatcher.do_dispatch_issue(state, issue, nil, nil, decision_store: store, runner: runner, rework_head_sha: nil)
      {:reply, :ok, next}
    end

    def handle_call(:worker_status, _from, state) do
      status = state.running |> Map.values() |> Enum.map(&get_in(&1, [:control, :status]))
      {:reply, status, state}
    end

    def handle_call(message, from, state), do: Orchestrator.handle_call(message, from, state)

    @impl true
    def handle_info(message, state), do: Orchestrator.handle_info(message, state)

    @impl true
    def terminate(_reason, state) do
      for entry <- Map.values(state.running) do
        monitor = Process.monitor(entry.pid)
        send(entry.pid, :stop)

        receive do
          {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
        after
          1_000 -> Process.exit(entry.pid, :kill)
        end
      end

      :ok
    end
  end

  setup do
    :ok = DecisionPubSub.subscribe()
    dir = Aiur.TestSupport.tmp_root!("override-legacy-delivery")
    previous = Application.fetch_env(:aiur, :control_lifecycle_store_path)
    Application.put_env(:aiur, :control_lifecycle_store_path, Path.join(dir, "controls.json"))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :control_lifecycle_store_path, value)
        :error -> Application.delete_env(:aiur, :control_lifecycle_store_path)
      end

      Aiur.TestCleanup.rm_rf!(dir)
    end)

    runtime = start_supervised!(Runtime)
    %{runtime: runtime, dir: dir}
  end

  test "before-delivery override replaces an absent worker answer in its first session input exactly once", ctx do
    store = start_store!(ctx)
    decision = answer!(store)
    pending = wait_for(store, decision.decision_id, & &1.pending_for_session?)
    revised = override!(store, pending, "replacement")
    assert revised.answer.action_id == pending.answer.action_id
    assert revised.active_action_id != pending.active_action_id
    assert revised.pending_for_session?

    worker = launch!(ctx.runtime, store)
    assert_receive {:first_session_input, ^worker, [answer]}, 2_000
    assert answer.action_id == revised.active_action_id
    assert answer.answer == "replacement"
    assert_session_consumed_once(store, revised, ctx.runtime)
    assert OperatorMessages.claim_next_queue_item(ctx.runtime, @identifier) == :empty
  end

  test "two absent-worker overrides deliver only the newest answer at session start", ctx do
    store = start_store!(ctx)
    decision = answer!(store)
    pending = wait_for(store, decision.decision_id, & &1.pending_for_session?)
    first = override!(store, pending, "earlier direction")
    latest = override!(store, first, "newest direction")
    assert [%{state: :superseded}, %{state: :queued}] = latest.overrides

    worker = launch!(ctx.runtime, store)
    assert_receive {:first_session_input, ^worker, [answer]}, 2_000
    assert answer.action_id == latest.active_action_id
    assert answer.answer == "newest direction"
    assert_session_consumed_once(store, latest, ctx.runtime)
    refute_receive {:worker_input, ^worker, _, _}, 0
    assert OperatorMessages.claim_next_queue_item(ctx.runtime, @identifier) == :empty
  end

  test "paused worker receives override as its first resumed input once, before later ordinary messages", ctx do
    store = start_store!(ctx)
    worker = launch!(ctx.runtime, store)
    assert_receive {:first_session_input, ^worker, []}, 2_000
    original = answer!(store)
    delivered = wait_for(store, original.decision_id, &(&1.delivery_status == :consumed))
    assert_receive {:worker_input, ^worker, original_action, _}, 2_000
    assert original_action == delivered.active_action_id

    assert {:ok, _} = PauseResume.request_control(ctx.runtime, @identifier, :pause, 3032)
    assert_receive {:worker_paused, ^worker}, 2_000
    assert GenServer.call(ctx.runtime, :worker_status) == [:paused]

    revised = override!(store, delivered, "first resumed direction")
    queued = wait_for(store, revised.decision_id, &(&1.delivery_status == :queued))
    assert queued.active_action_id == revised.active_action_id
    assert GenServer.call(ctx.runtime, :worker_status) == [:paused]
    refute_receive {:worker_input, ^worker, _, _}, 0

    # A plain message sent during a pause intentionally becomes the causal
    # resume input. Exercise explicit resume here, then add competing input
    # while the resumed provider is held just before its first queue claim.
    assert {:ok, _} = PauseResume.request_control(ctx.runtime, @identifier, :resume, 3033)
    assert_receive {:resume_waiting, ^worker}, 2_000
    send(worker, :allow_resume)
    assert_receive {:worker_resumed, ^worker}, 2_000
    assert GenServer.call(ctx.runtime, :worker_status) == [:working]
    assert {:ok, _} = OperatorMessages.send_operator_message(ctx.runtime, @identifier, %{kind: :text, body: "later ordinary message"})
    send(worker, :allow_input)
    assert_receive {:worker_input, ^worker, action, body}, 2_000
    assert action == revised.active_action_id
    assert body =~ "Replacement response: first resumed direction"
    assert GenServer.call(ctx.runtime, :worker_status) == [:working]
    wait_for(store, revised.decision_id, &(&1.delivery_status == :consumed))

    send(worker, :read_next)
    assert_receive {:worker_input, ^worker, nil, "later ordinary message"}, 2_000
    send(worker, :read_next)
    assert_receive {:worker_queue_empty, ^worker}, 2_000
    assert {:ok, history} = DecisionStore.audit_history(revised.decision_id, store)
    assert Enum.count(history, &(&1.type == :delivered and &1.data.action_id == action)) == 1
  end

  test "merged PR override preserves terminal target follow-up instead of silently staying queued", ctx do
    store = start_store!(ctx, "done")
    worker = launch!(ctx.runtime, store)
    assert_receive {:first_session_input, ^worker, []}, 2_000
    original = answer!(store)
    delivered = wait_for(store, original.decision_id, &(&1.delivery_status == :consumed))
    assert_receive {:worker_input, ^worker, _, _}, 2_000
    context = %{@context | pr: %{@context.pr | merged?: true}}
    revised = override!(store, delivered, "correct merged work", context)
    terminal = wait_for(store, revised.decision_id, &(map_size(&1.revision_follow_ups) == 1))
    action = revised.active_action_id
    assert [%{route: :corrective_ticket, action_id: ^action}] = terminal.overrides
    assert terminal.revision_outcomes[action].reason_class == "target_terminal"
    assert terminal.revision_follow_ups[action].handled_at == nil
    assert_receive {:follow_up, ^action}, 2_000
    assert {:ok, history} = DecisionStore.audit_history(revised.decision_id, store)
    assert Enum.count(history, &(&1.type == :follow_up_required and &1.data.action_id == action)) == 1
    refute_receive {:worker_input, ^worker, ^action, _}, 0
  end

  defp start_store!(ctx, target_state \\ "in-progress") do
    parent = self()

    dispatcher = fn decision, opts ->
      DecisionDispatch.dispatch(
        decision,
        opts ++
          [
            operator_messages: ctx.runtime,
            send_fun: &OperatorMessages.send_correlated_operator_message/3,
            issue_fetcher: fn _ -> {:ok, [%Issue{id: @identifier, identifier: @identifier, title: "Override", state: target_state}]} end,
            terminal_states: MapSet.new(["done"]),
            revalidate_fun: &Aiur.Orchestrator.Dispatcher.revalidate_issue_for_dispatch/3
          ]
      )
    end

    start_supervised!(
      {DecisionStore,
       name: nil,
       state_dir: ctx.dir,
       filesystem_sync_fun: fn -> :ok end,
       dispatch_delay_ms: 0,
       retry_delays_ms: [],
       reconcile_delay_ms: 60_000,
       dispatcher: dispatcher,
       answer_comment_publisher: fn _ -> :ok end,
       revision_follow_up_projector: fn _, action ->
         send(parent, {:follow_up, action})
         :ok
       end}
    )
  end

  defp answer!(store) do
    assert {:ok, %{decision: decision}} =
             DecisionStore.request(%{source_id: "legacy", question: "Which direction?", blocking: false}, [ticket: %{identifier: @identifier, title: "Override", url: nil}, source: @source], store)

    assert {:ok, %{decision: answered}} = DecisionStore.answer(decision.decision_id, payload("original direction"), [actor: @actor], store)
    answered
  end

  defp override!(store, decision, text, context \\ @context) do
    assert {:ok, %{status: :accepted, decision: revised}} = DecisionStore.override(decision.decision_id, payload(text), [actor: @actor, override_context: context], store)
    revised
  end

  defp payload(text), do: %{expected_version: 1, custom_response: text, rationale: "New direction", idempotency_key: text}

  defp launch!(runtime, store) do
    parent = self()

    runner = fn issue, recipient, opts ->
      send(parent, {:worker_started, self()})
      send(parent, {:first_session_input, self(), opts[:answered_decisions]})
      now = DateTime.utc_now()
      send(recipient, {:codex_worker_update, issue.id, %{event: :session_started, timestamp: now, thread_id: "new-session"}})
      send(recipient, {:codex_worker_update, issue.id, %{event: :notification, timestamp: now, payload: %{"method" => "turn/started"}}})
      worker_loop(parent, recipient, issue, store, :working)
    end

    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => "I_override_6908", "database_id" => 6908, "number" => 6908}, {"owner", "repo"}, {"owner", "repo"})
    issue = %Issue{id: @identifier, identifier: @identifier, tracker_identity: identity, title: "Override", state: "in-progress", selected_backend: "codex"}
    assert :ok = GenServer.call(runtime, {:launch, issue, store, runner})
    assert_receive {:worker_started, worker}, 2_000
    worker
  end

  defp worker_loop(parent, runtime, issue, store, phase) do
    receive do
      {:pause_agent, request, generation} ->
        send(runtime, {:worker_control_state, issue.id, :paused, %{request_id: request, generation: generation}})
        send(parent, {:worker_paused, self()})
        worker_loop(parent, runtime, issue, store, :paused)

      {:resume_agent, request, generation} ->
        send(parent, {:resume_waiting, self()})
        worker_loop(parent, runtime, issue, store, {:resume_wait, request, generation})

      :allow_resume ->
        {:resume_wait, request, generation} = phase
        send(runtime, {:worker_control_state, issue.id, :working, %{request_id: request, generation: generation}})
        GenServer.call(runtime, :worker_status)
        send(parent, {:worker_resumed, self()})
        worker_loop(parent, runtime, issue, store, :resumed_wait)

      :allow_input when phase == :resumed_wait ->
        read_input(parent, runtime, issue, store)
        worker_loop(parent, runtime, issue, store, :working)

      {:agent_queue_updated, _, _, true} when phase == :working ->
        read_input(parent, runtime, issue, store)
        worker_loop(parent, runtime, issue, store, phase)

      :read_next ->
        read_input(parent, runtime, issue, store)
        worker_loop(parent, runtime, issue, store, phase)

      :stop ->
        :ok

      _notice ->
        worker_loop(parent, runtime, issue, store, phase)
    end
  end

  defp read_input(parent, runtime, issue, store) do
    case OperatorMessages.claim_next_queue_item(runtime, issue.identifier) do
      {:ok, item} ->
        if item.action_id do
          :ok = accept_delivery(item, store)
        end

        :ok = OperatorMessages.mark_queue_item_consumed(runtime, item.id)
        :ok = DecisionStore.record_transport_batch_async(:consumed, [item], nil, store)
        send(parent, {:worker_input, self(), item.action_id, item.body.text})

      :empty ->
        send(parent, {:worker_queue_empty, self()})
    end
  end

  defp accept_delivery(item, store) do
    {:ok, :accepted} = DecisionStore.validate_delivery(item, store)
    {:ok, :accepted} = DecisionStore.record_delivery(item, store)
    :ok
  end

  defp assert_session_consumed_once(store, decision, runtime) do
    wait_for(store, decision.decision_id, &(!&1.pending_for_session?))
    update = %{event: :notification, timestamp: DateTime.utc_now(), payload: %{"method" => "turn/started"}}
    send(runtime, {:codex_worker_update, @identifier, update})
    GenServer.call(runtime, :worker_status)
    assert {:ok, history} = DecisionStore.audit_history(decision.decision_id, store)
    assert [%{data: %{action_id: action}}] = Enum.filter(history, &(&1.type == :session_started))
    assert action == decision.active_action_id
  end

  defp wait_for(store, id, predicate), do: wait_for(store, id, predicate, System.monotonic_time(:millisecond) + 3_000)

  defp wait_for(store, id, predicate, deadline) do
    assert {:ok, decision} = DecisionStore.get(id, store)

    if predicate.(decision) do
      decision
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:decision_changed, ^id, _version} -> wait_for(store, id, predicate, deadline)
      after
        remaining -> flunk("Decision did not reach expected state: #{inspect(decision, limit: 30)}")
      end
    end
  end
end

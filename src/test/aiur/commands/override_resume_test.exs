defmodule Aiur.Commands.OverrideResumeTest do
  use ExUnit.Case, async: false
  alias Aiur.AgentRunner.{QueueTurn, TurnPrompt}
  alias Aiur.{Commands, DecisionStore, Issue}
  alias Aiur.Commands.OverridePrompt
  alias Aiur.Orchestrator.{OverrideResume, Slots, State}

  defmodule QueueServer do
    use GenServer
    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)
    @impl true
    def init(nil), do: {:ok, nil}
    @impl true
    def handle_call({:consume_delivered_queue_items, _}, _from, state), do: {:reply, :ok, state}
    def handle_call({:claim_next_queue_item, _}, _from, state), do: {:reply, :empty, state}
  end

  setup do
    dir = Aiur.TestSupport.tmp_root!("override-resume-6909")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    opts = [name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, dispatch_delay_ms: 60_000, answer_comment_publisher: fn _ -> :ok end]
    store = start_supervised!({DecisionStore, opts})

    {:ok, %{decision: decision}} =
      Commands.request(
        %{question: "Which direction?", blocking: true, source_id: "resume-test", authority: :supervisor_allowed, reversibility: :reversible},
        [ticket: %{identifier: "6909", title: "Override", url: nil}, source: %{agent_id: "worker", session_id: "session"}],
        store
      )

    actor = [actor: %{kind: :operator, id: "human"}, actor_source: :dashboard_session]
    {:ok, %{decision: first}} = Commands.answer(decision.decision_id, payload("first", "Initial direction"), actor, store)
    context = %{pr: %{number: 77, merged?: false, head_sha: "before"}, worker: :resumable, capacity: :full}
    override_opts = Keyword.put(actor, :override_context, context)
    {:ok, %{decision: override}} = Commands.override(first.decision_id, payload("second", "Use the new direction"), override_opts, store)
    issue = %Issue{id: "6909", identifier: "6909", title: "Override", state: "in-progress", labels: ["agent:in-progress"]}
    %{store: store, store_opts: opts, decision: override, issue: issue, override_opts: override_opts}
  end

  test "override is first on cold, resumed and continuation turns until acknowledged", ctx do
    opts = OverridePrompt.prepare(ctx.issue.identifier, decision_store: ctx.store)

    for {turn, mode} <- [{1, []}, {1, [resumed: true]}, {2, []}, {3, []}] do
      prompt = TurnPrompt.build_turn_prompt(ctx.issue, Keyword.merge(opts, mode), turn, 12)
      assert String.starts_with?(prompt, "Operator override — this replaces your earlier instruction for Command #{ctx.decision.decision_id}")
      assert prompt =~ "Use the new direction"
      assert prompt =~ "decision.acknowledged"
    end

    assert :ok = OverridePrompt.received(%{event: :notification, payload: %{"method" => "turn/started"}}, opts)
    {:ok, delivered} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert [%{state: :delivered, delivered_at: at}] = delivered.overrides
    assert match?(%DateTime{}, at)

    assert {:ok, _} =
             Commands.record_command_fact(ctx.decision.decision_id, :override_implemented, %{action_id: ctx.decision.active_action_id, head_sha: "after", pr_number: 77, at: DateTime.add(at, 1)},
               server: ctx.store
             )

    assert OverridePrompt.prepare(ctx.issue.identifier, decision_store: ctx.store)[:pending_overrides] != []

    assert {:ok, %{decision_status: :acknowledged}} =
             Commands.agent_lifecycle(
               :acknowledged,
               %{decision_id: ctx.decision.decision_id, action_id: ctx.decision.active_action_id, expected_version: 1},
               [ticket_identifier: ctx.issue.identifier, actor: %{kind: :agent, id: "worker"}, source: %{agent_id: "worker", session_id: "session", invocation_id: "ack"}],
               ctx.store
             )

    assert OverridePrompt.prepare(ctx.issue.identifier, decision_store: ctx.store)[:pending_overrides] == []
    {:ok, done} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert [%{state: :implemented, evidence: %{kind: :push, head_sha: "after"}}] = done.overrides
  end

  test "capacity wait survives restart then resumes only one worker on the same ticket", ctx do
    busy = %Issue{id: "busy", identifier: "busy", state: "in-progress"}
    state = %State{max_concurrent_agents: 1, running: %{busy.id => entry(busy)}}
    full = apply_request(state, ctx)
    assert Slots.active_slots(full) == 1
    refute_received {:resumed, _}
    assert {:ok, waiting} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert [%{route: :capacity_wait, resume_reason: :capacity}] = waiting.overrides
    assert :ok = stop_supervised(DecisionStore)
    store = start_supervised!({DecisionStore, ctx.store_opts})
    ctx = %{ctx | store: store}
    assert [restored] = OverrideResume.waiting(Commands.list_decisions(store))
    assert restored.active_action_id == ctx.decision.active_action_id
    resumed = apply_request(%{full | running: %{}}, ctx)
    assert_received {:resumed, "6909"}
    assert Slots.active_slots(resumed) == 1
    assert Map.keys(resumed.running) == [ctx.issue.id]
    assert apply_request(resumed, ctx) == resumed
    refute_received {:resumed, _}
  end

  test "CPU and memory holds keep a free slot and remain visible", ctx do
    for signal <- [:cpu_pressure, :memory, :prewarm] do
      state = apply_request(%State{max_concurrent_agents: 1}, ctx, admission_fun: fn _ -> {:hold, signal} end)
      assert state.running == %{}
    end

    refute_received {:resumed, _}
    {:ok, waiting} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert [%{route: :capacity_wait, resume_reason: :capacity}] = waiting.overrides
  end

  test "three waiting overrides inject only the newest and resume once", ctx do
    {:ok, %{decision: third}} = Commands.override(ctx.decision.decision_id, payload("third", "Third direction"), ctx.override_opts, ctx.store)
    {:ok, %{decision: newest}} = Commands.override(third.decision_id, payload("fourth", "Newest direction"), ctx.override_opts, ctx.store)
    assert [%{state: :superseded}, %{state: :superseded}, %{state: :queued}] = newest.overrides
    assert [selected] = OverrideResume.waiting(Commands.list_decisions(ctx.store))
    assert selected.active_action_id == newest.active_action_id
    opts = OverridePrompt.prepare(ctx.issue.identifier, decision_store: ctx.store)
    prompt = TurnPrompt.build_turn_prompt(ctx.issue, opts, 2, 12)
    assert prompt =~ "Newest direction"
    refute prompt =~ "Third direction"
    refute prompt =~ "Use the new direction"
    state = apply_request(%State{max_concurrent_agents: 1}, %{ctx | decision: newest})
    assert Slots.active_slots(state) == 1
    assert_received {:resumed, "6909"}
    refute_received {:resumed, _}
  end

  test "label park stays parked and raises a Resume Command", ctx do
    assert_operator_hold(%State{max_concurrent_agents: 1}, %{ctx | issue: %{ctx.issue | parked: true}})
  end

  test "label pause stays paused and raises a Resume Command", ctx do
    assert_operator_hold(%State{max_concurrent_agents: 1}, %{ctx | issue: %{ctx.issue | paused: true}})
  end

  test "operator CLI pause without a label stays paused and raises a Resume Command", ctx do
    alias Aiur.Orchestrator.PauseResume.PauseRequest
    worker = Map.merge(entry(ctx.issue), %{pid: self(), started_at: DateTime.utc_now(), control: %{status: :working, can_interrupt: true}})
    state = %State{max_concurrent_agents: 1, running: %{ctx.issue.id => worker}}
    assert {{:ok, request_id}, paused} = PauseRequest.pause_agent_reply(state, ctx.issue.identifier)
    assert_received {:pause_agent, ^request_id}
    assert paused.running[ctx.issue.id].paused_reason == :operator_pause
    next = assert_operator_hold(paused, ctx)
    assert next.running[ctx.issue.id] == paused.running[ctx.issue.id]
    refute_received {:resume_agent, _}
  end

  test "requested and accepted operator pauses stay pending and raise a Resume Command", ctx do
    alias Aiur.Orchestrator.ControlLifecycle
    identity = %Aiur.TrackerIdentity{version: 1, status: :joinable, kind: :github, owner: "aiur-team", repository: "aiur", provider_id: "I_kwDOissue1", identifier: "6909", reason: nil}
    attrs = %{request_id: "pause", issue_id: ctx.issue.id, tracker_identity: identity, action: :pause, generation: "worker", expected_status: :working, expected_version: 1, requester: :operator}
    {:ok, _, requested} = ControlLifecycle.request(ControlLifecycle.new(), attrs)
    {:ok, _, accepted} = ControlLifecycle.accept(requested, "pause", "worker")

    for lifecycle <- [requested, accepted] do
      worker = Map.put(entry(ctx.issue), :pending_pause_reason, %{request_id: "pause", reason: :operator_pause})
      state = %State{max_concurrent_agents: 1, running: %{ctx.issue.id => worker}, control_lifecycle: lifecycle}
      next = assert_operator_hold(state, ctx)
      assert next.running == state.running
      assert next.control_lifecycle == lifecycle
      refute_received {:resume_agent, _}
    end
  end

  test "merged, unknown and superseded async snapshots cannot resume", ctx do
    state = %State{max_concurrent_agents: 1}
    assert Slots.active_slots(apply_request(state, ctx)) == 1
    assert_received {:resumed, "6909"}
    assert OverrideResume.apply_loaded(state, [{ctx.decision, {:ok, [ctx.issue]}, {:ok, %{merged?: true}}}], decision_store: ctx.store) == state
    assert OverrideResume.apply_loaded(state, [{ctx.decision, {:ok, [ctx.issue]}, {:error, :unavailable}}], decision_store: ctx.store) == state
    {:ok, %{decision: _}} = Commands.override(ctx.decision.decision_id, payload("newer", "Newer"), ctx.override_opts, ctx.store)
    assert apply_request(state, ctx) == state
    refute_received {:resumed, _}
  end

  for reason <- [:agent_pause_request, :input_required, :capacity] do
    @pause_reason reason
    test "#{reason} pause resumes the same runner through normal control", ctx do
      worker = %{issue: ctx.issue, identifier: ctx.issue.identifier, pid: self(), started_at: DateTime.utc_now(), paused_reason: @pause_reason, control: %{status: :paused, can_interrupt: true}}
      state = %State{max_concurrent_agents: 1, running: %{ctx.issue.id => worker}}
      next = OverrideResume.apply_loaded(state, [{ctx.decision, {:ok, [ctx.issue]}, {:ok, nil}}], decision_store: ctx.store, admission_fun: fn _ -> :dispatch end)

      assert_received {:resume_agent, request_id}
      assert is_integer(request_id)
      assert next.running[ctx.issue.id].pid == self()
      assert next.running[ctx.issue.id].control.status == :working
      assert Slots.active_slots(next) == 1
      assert Map.keys(next.running) == [ctx.issue.id]
      refute Enum.any?(Commands.list_decisions(ctx.store), &(&1.question == "Resume #6909 to apply the override?"))
    end
  end

  test "fresh terminal issue prevents resuming an existing paused runner", ctx do
    # Positive witness makes a no-op scheduler fail this regression guard.
    assert Slots.active_slots(apply_request(%State{max_concurrent_agents: 1}, ctx)) == 1
    assert_received {:resumed, "6909"}
    stopped = %{ctx.issue | state: "done", labels: ["agent:done"]}
    paused = %{entry(stopped) | control: %{status: :paused}}
    state = %State{max_concurrent_agents: 1, running: %{stopped.id => paused}}
    assert apply_request(state, %{ctx | issue: stopped}).running == state.running
    refute_received {:resumed, _}
  end

  test "parked override creates one real Executor Command without resuming", ctx do
    issue = %{ctx.issue | parked: true}

    state =
      OverrideResume.apply_loaded(
        %State{max_concurrent_agents: 1},
        [{ctx.decision, {:ok, [issue]}, {:ok, nil}}],
        decision_store: ctx.store
      )

    assert state.running == %{}
    assert [command] = Enum.filter(Commands.list_decisions(ctx.store), &(&1.question == "Resume #6909 to apply the override?"))
    assert command.requester.kind == :executor
    assert Enum.map(command.options, & &1.id) == ["resume", "keep"]
    OverrideResume.apply_loaded(state, [{ctx.decision, {:ok, [issue]}, {:ok, nil}}], decision_store: ctx.store)
    assert Enum.count(Commands.list_decisions(ctx.store), &(&1.question == command.question)) == 1
  end

  test "a pending resume reserves released capacity before ordinary dispatch", ctx do
    alias Aiur.Orchestrator.ControlLifecycle
    identity = %Aiur.TrackerIdentity{version: 1, status: :joinable, kind: :github, owner: "aiur-team", repository: "aiur", provider_id: "I_kwDOissue1", identifier: "6909", reason: nil}
    issue = %{ctx.issue | state: "ci-wait", tracker_identity: identity}
    entry = %{entry(issue) | control: %{status: :paused}}
    attrs = %{request_id: "resume", issue_id: issue.id, tracker_identity: identity, action: :resume, generation: "worker", expected_status: :paused, expected_version: 1, requester: :automatic}
    {:ok, _, lifecycle} = ControlLifecycle.request(ControlLifecycle.new(), attrs)
    {:ok, _, lifecycle} = ControlLifecycle.accept(lifecycle, "resume", "worker")
    state = %State{max_concurrent_agents: 1, running: %{issue.id => entry}, control_lifecycle: lifecycle}
    assert Slots.active_slots(state) == 1
    assert Slots.available_slots(state) == 0
    refute Slots.dispatch_slots_available?(%Issue{id: "other", state: "in-progress"}, state)
    {:ok, _, lifecycle} = ControlLifecycle.apply(lifecycle, "resume", "worker")
    active = %{state | control_lifecycle: lifecycle, running: %{issue.id => %{entry | control: %{status: :working}}}}
    assert Slots.active_slots(active) == 1
    assert Slots.used_slots(active) == 1
  end

  test "queued-message provider turn refreshes and prepends the pending override", ctx do
    server = start_supervised!(QueueServer)
    item = %{id: 1, category: :operator_message, body: %{text: "Queued superseded instructions"}}

    assert :ok =
             QueueTurn.run_queue_item_turn(
               %{backend: "codex", thread_id: "queue-thread"},
               ctx.issue,
               item,
               fn _ -> :ok end,
               server,
               nil,
               decision_store: ctx.store,
               pending_overrides: [],
               run_turn: fn _session, text, _issue, turn_opts ->
                 assert String.starts_with?(text, "Operator override — this replaces your earlier instruction for Command")
                 assert text =~ "Use the new direction"
                 assert String.ends_with?(text, "Queued superseded instructions")
                 turn_opts[:on_message].(%{event: :notification, timestamp: DateTime.utc_now(), payload: %{"method" => "turn/started", "params" => %{}}})
                 {:ok, %{session_id: "queue-session"}}
               end
             )

    {:ok, pending} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert [%{state: :delivered, delivered_at: %DateTime{}}] = pending.overrides
  end

  test "waiting requests are admitted oldest first with one resume per ticket", ctx do
    {:ok, %{decision: other}} =
      Commands.request(
        %{question: "Second ticket direction?", blocking: false, source_id: "fifo-other", authority: :supervisor_allowed, reversibility: :reversible},
        [ticket: %{identifier: "other"}, source: %{agent_id: "other", session_id: "other"}],
        ctx.store
      )

    {:ok, %{decision: other}} = Commands.answer(other.decision_id, payload("other-first", "Initial"), ctx.override_opts, ctx.store)

    {:ok, %{decision: other}} =
      Commands.override(other.decision_id, payload("other-next", "Other override"), Keyword.put(ctx.override_opts, :now, DateTime.add(List.last(ctx.decision.overrides).queued_at, 1)), ctx.store)

    assert [first, second] = OverrideResume.waiting([other, ctx.decision, ctx.decision])
    assert first.decision_id == ctx.decision.decision_id
    assert second.decision_id == other.decision_id
    state = apply_request(%State{max_concurrent_agents: 1}, ctx)
    other_issue = %{ctx.issue | id: "other", identifier: "other"}
    final = apply_request(state, %{ctx | decision: other, issue: other_issue})
    assert Map.keys(final.running) == [ctx.issue.id]
    assert Slots.active_slots(final) == 1
    assert_received {:resumed, "6909"}
    refute_received {:resumed, "other"}
  end

  defp assert_operator_hold(state, ctx) do
    next = OverrideResume.apply_loaded(state, [{ctx.decision, {:ok, [ctx.issue]}, {:ok, nil}}], decision_store: ctx.store, admission_fun: fn _ -> :dispatch end)
    remembered = Map.get(next.running, ctx.issue.id)
    assert if(remembered, do: remembered.issue, else: next.last_polled_issues[ctx.issue.id]) == ctx.issue
    assert [%{requester: %{kind: :executor}}] = Enum.filter(Commands.list_decisions(ctx.store), &(&1.question == "Resume #6909 to apply the override?"))
    {:ok, waiting} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert [%{route: :resume_pending, resume_reason: :operator_pause}] = waiting.overrides
    next
  end

  defp apply_request(state, ctx, opts \\ []) do
    parent = self()

    defaults = [
      decision_store: ctx.store,
      admission_fun: fn _ -> :dispatch end,
      resume_fun: fn current, issue, _entry ->
        send(parent, {:resumed, issue.identifier})
        next = put_in(current.running[issue.id], entry(issue))
        assert Slots.active_slots(next) <= Slots.max_concurrent_agent_limit(next)
        {{:ok, :started}, next}
      end
    ]

    OverrideResume.apply_loaded(state, [{ctx.decision, {:ok, [ctx.issue]}, {:ok, nil}}], Keyword.merge(defaults, opts))
  end

  defp entry(issue), do: %{identifier: issue.identifier, issue: issue, control: %{status: :working}}
  defp payload(key, text), do: %{expected_version: 1, idempotency_key: key, custom_response: text, rationale: "Changed direction"}
end

defmodule Aiur.Orchestrator.SelfPauseAnswerTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.{AgentControlCLI, DecisionDispatch, DecisionStore, Issue}
  alias Aiur.AgentRunner.QueueDrain
  alias Aiur.Orchestrator.{ControlLifecycle, OperatorMessages, PauseResume, PushRouting, StatusReport}

  setup do
    orchestrator = Process.whereis(Orchestrator)
    original = :sys.get_state(orchestrator)
    parent = self()
    store = Process.whereis(DecisionStore)
    dispatcher = :sys.get_state(store).dispatcher

    :sys.replace_state(store, fn state ->
      %{
        state
        | dispatcher: fn decision, opts ->
            result = DecisionDispatch.dispatch(decision, opts)
            send(parent, {:answer_queued, result})
            result
          end
      }
    end)

    :sys.replace_state(orchestrator, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

      %{
        state
        | running: %{},
          last_polled_issues: %{},
          control_lifecycle: %ControlLifecycle{},
          tick_timer_ref: nil,
          tick_token: make_ref(),
          poll_frozen: true,
          globally_paused: false,
          max_concurrent_agents: 1,
          effective_concurrent_agents: 1,
          waiting_for_human_episodes: %{}
      }
    end)

    on_exit(fn ->
      :sys.replace_state(store, &%{&1 | dispatcher: dispatcher})
      :sys.replace_state(orchestrator, fn _ -> original end)
    end)

    %{orchestrator: orchestrator}
  end

  for phase <- [:pending, :paused] do
    test "answer resumes a #{phase} self-pause with the answer as first input", ctx do
      {issue, worker} = install_worker(ctx.orchestrator)
      decision = request_decision(issue)
      pause(ctx.orchestrator, issue, unquote(phase))
      answer(decision)

      assert %{action: :resume, status: :accepted} =
               ControlLifecycle.current_pending(:sys.get_state(ctx.orchestrator).control_lifecycle, issue.id)

      send(worker, :run)
      receive_barrier({:first_input, text})
      assert text =~ "Custom response: Continue with the accepted contract"
      assert_working(ctx.orchestrator, issue)
    end
  end

  test "the answer precedes a restored interrupt input on resume", ctx do
    {issue, worker} = install_worker(ctx.orchestrator)

    assert {:ok, old_id} =
             OperatorMessages.send_operator_message(ctx.orchestrator, issue.identifier, %{kind: :text, body: "Earlier interrupted input", delivery_policy: :interrupt, fallback: :queue_next})

    assert {:ok, %{id: ^old_id}} = OperatorMessages.claim_next_queue_item(ctx.orchestrator, issue.identifier)
    assert :ok = OperatorMessages.restore_delivered_queue_items(ctx.orchestrator, issue.identifier)
    send(worker, {:discard_queue_notice, old_id, self()})
    receive_barrier(:queue_notice_discarded)
    decision = request_decision(issue)
    pause(ctx.orchestrator, issue, :paused)
    answer(decision)
    send(worker, :run)
    receive_barrier({:first_input, text})
    assert text =~ "Custom response: Continue with the accepted contract"
    assert {:ok, :pending} = OperatorMessages.operator_message_status(ctx.orchestrator, old_id)
    assert_working(ctx.orchestrator, issue)
  end

  test "operator message clears a self-pause and cannot start another waiting episode", ctx do
    {issue, worker} = install_worker(ctx.orchestrator)
    pause(ctx.orchestrator, issue, :paused)
    seed_waiting_episode(ctx.orchestrator, issue)
    assert {:ok, _} = OperatorMessages.send_operator_message(ctx.orchestrator, issue.identifier, %{kind: :text, body: "Continue", delivery_policy: :interrupt, fallback: :queue_next})
    send(worker, :run)
    receive_barrier({:first_input, "Continue"})
    assert_working(ctx.orchestrator, issue)
  end

  test "uncorrelated turn start clears a stale self-pause", ctx do
    {issue, _worker} = install_worker(ctx.orchestrator)
    pause(ctx.orchestrator, issue, :paused)
    seed_waiting_episode(ctx.orchestrator, issue)
    send(ctx.orchestrator, {:worker_control_state, issue.id, :working})
    assert_working(ctx.orchestrator, issue)
  end

  for reason <- [:operator_pause, :label_override] do
    test "an answer and its replay preserve #{reason} until explicit resume", ctx do
      {issue, worker} = install_worker(ctx.orchestrator)
      decision = request_decision(issue)

      :sys.replace_state(ctx.orchestrator, fn state ->
        entry = state.running[issue.id] |> put_in([:control, :status], :paused) |> Map.put(:paused_reason, unquote(reason))
        %{state | running: %{issue.id => entry}}
      end)

      answer(decision)
      assert {:ok, decided} = DecisionStore.get(decision.decision_id)
      assert {:ok, %{status: :duplicate}} = DecisionDispatch.dispatch(decided, attempt_id: "replay")
      assert :sys.get_state(ctx.orchestrator).running[issue.id].control.status == :paused
      # Inspect the actual messages the paused receive loop would see; none
      # may wake it. This barrier avoids a timing-based negative assertion.
      send(worker, {:mailbox, self()})
      receive_barrier({:mailbox, messages})
      refute Enum.any?(messages, &match?({:resume_agent, _, _}, &1))
      refute Enum.any?(messages, &match?({:agent_queue_updated, _, _, true}, &1))
      assert {:ok, :resumed} = PauseResume.resume_agent(ctx.orchestrator, issue.identifier)
      send(worker, :run)
      receive_barrier({:first_input, text})
      assert text =~ "Continue with the accepted contract"
    end
  end

  for hold <- [:global, :label] do
    test "an answer preserves a #{hold} hold over a pending self-pause", ctx do
      {issue, worker} = install_worker(ctx.orchestrator)
      decision = request_decision(issue)
      pause(ctx.orchestrator, issue, :pending)

      :sys.replace_state(ctx.orchestrator, fn state ->
        case unquote(hold) do
          :global -> %{state | globally_paused: true}
          :label -> put_in(state.running[issue.id].issue.paused, true)
        end
      end)

      answer(decision)
      assert {:ok, decided} = DecisionStore.get(decision.decision_id)
      assert {:ok, %{status: :duplicate}} = DecisionDispatch.dispatch(decided, attempt_id: "replay")
      send(worker, {:mailbox, self()})
      receive_barrier({:mailbox, messages})
      refute Enum.any?(messages, &match?({:resume_agent, _, _}, &1))
      refute Enum.any?(messages, &match?({:agent_queue_updated, _, _, true}, &1))
      assert %{action: :pause} = ControlLifecycle.current_pending(:sys.get_state(ctx.orchestrator).control_lifecycle, issue.id)
    end
  end

  defp install_worker(orchestrator) do
    id = "2730#{System.unique_integer([:positive])}"

    issue = %Issue{
      id: id,
      identifier: id,
      title: "Self pause",
      state: "in-progress",
      tracker_identity: %Aiur.TrackerIdentity{version: 1, status: :joinable, kind: :github, owner: "owner", repository: "repo", provider_id: "I_#{id}", identifier: id, reason: nil}
    }

    parent = self()
    worker = spawn(fn -> await_run(orchestrator, issue, parent) end)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

    entry = %{
      pid: worker,
      ref: make_ref(),
      identifier: id,
      issue: issue,
      session_id: "thread-#{id}",
      started_at: DateTime.utc_now(),
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      control: %{status: :working, can_interrupt: true, safe_checkpoints: [:notification], generation: 1, version: 1, application_confirmation: :confirmed}
    }

    :sys.replace_state(orchestrator, &%{&1 | running: %{id => entry}})
    {issue, worker}
  end

  defp await_run(orchestrator, issue, parent) do
    receive do
      {:discard_queue_notice, item_id, caller} ->
        receive do
          {:agent_queue_updated, _, ^item_id, _} -> send(caller, :queue_notice_discarded)
        end

        await_run(orchestrator, issue, parent)

      {:mailbox, caller} ->
        {:messages, messages} = Process.info(self(), :messages)
        send(caller, {:mailbox, messages})
        await_run(orchestrator, issue, parent)

      :run ->
        QueueDrain.wait_for_operator_message(%{backend: "codex", thread_id: "thread-#{issue.id}"}, issue, fn _ -> :ok end, orchestrator, orchestrator,
          run_turn: fn session, text, _issue, opts ->
            :ok = opts[:on_provider_delivery].(%{turn_id: "answer-turn"})
            # The synchronous queue receipt fences the preceding working update.
            send(parent, {:first_input, text})
            receive do: (:finish -> {:ok, session})
          end
        )
    end
  end

  defp pause(orchestrator, issue, phase) do
    :sys.replace_state(orchestrator, &PushRouting.maybe_pause_on_request(&1, issue.identifier))

    state = :sys.get_state(orchestrator)
    request = ControlLifecycle.current_pending(state.control_lifecycle, issue.id)
    assert %{action: :pause, status: :accepted} = request

    if phase == :paused do
      send(orchestrator, {:worker_control_state, issue.id, :paused, %{request_id: request.request_id, generation: request.generation}})
      assert :sys.get_state(orchestrator).running[issue.id].paused_reason == :agent_pause_request
    end
  end

  defp request_decision(issue) do
    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{"question" => "May I continue?", "blocking" => true, "authority" => "supervisor_allowed", "reversibility" => "reversible"},
               ticket: %{identifier: issue.identifier, title: issue.title, url: nil},
               source: %{agent_id: issue.id, session_id: "thread-#{issue.id}"}
             )

    decision
  end

  defp answer(decision) do
    assert {:ok, %{status: :accepted}} =
             DecisionStore.answer(
               decision.decision_id,
               %{"idempotency_key" => decision.decision_id, "expected_version" => decision.version, "custom_response" => "Continue with the accepted contract", "rationale" => "Approved"},
               actor: %{kind: :executor, id: "executor"}
             )

    receive_barrier({:answer_queued, result})
    assert {:ok, _} = result
  end

  defp seed_waiting_episode(orchestrator, issue) do
    :sys.replace_state(orchestrator, fn state ->
      %{state | waiting_for_human_episodes: %{issue.identifier => %{since: DateTime.add(DateTime.utc_now(), -1200), alerted?: false}}}
    end)
  end

  defp assert_working(orchestrator, issue) do
    state = :sys.get_state(orchestrator)
    assert state.running[issue.id].control.status == :working
    refute Map.has_key?(state.running[issue.id], :paused_reason)
    [row] = StatusReport.agent_statuses(state)
    assert row.waiting_reason == :active
    assert row.pause_reason == nil
    next = StatusReport.sync_waiting_for_human_episodes(state, DateTime.add(DateTime.utc_now(), 1200))
    refute Map.has_key?(next.waiting_for_human_episodes, issue.identifier)
    refute Aiur.AlertFeed.active_ticket_attention?("ticket.#{issue.identifier}.agent.attention.waiting_for_human")
    snapshot = StatusReport.snapshot_payload(next) |> Map.put(:statuses, [row])
    view = {:ok, snapshot, %{status: :fresh}}
    status = capture_io(fn -> AgentControlCLI.status(fleet_view: view) end)
    agents = capture_io(fn -> AgentControlCLI.agents(fleet_view: view) end)
    refute status =~ "waiting_for_human"
    refute agents =~ "waiting_for_human"
    assert agents =~ "working"
  end
end

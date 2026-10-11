defmodule Aiur.Orchestrator.OperatorMessages.DeliveryMatrixTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentQueueStore, CodingAgent, Issue, TrackerIdentity}
  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Orchestrator.{ControlLifecycle, OperatorMessages, State}

  @moduletag :r7_characterization
  # Regression guards: these deliberately pass on main before the R7 moves.
  @checkpoint %{priority: :next, durability: :durable, consume_at: :safe_checkpoint, interrupt_requested: false, immediate: false, fallback: nil}
  @interrupt %{@checkpoint | priority: :now, interrupt_requested: true}
  @immediate %{@checkpoint | priority: :now, consume_at: :immediate, immediate: true}
  @unsupported {:error, :immediate_not_supported}
  @profiles [
    {"codex", [@checkpoint, @checkpoint, @interrupt, %{@interrupt | fallback: :queue_next}, @unsupported]},
    {"claude", [@checkpoint, @checkpoint, @interrupt, %{@interrupt | fallback: :queue_next}, @unsupported]},
    {"claude-repl", [@immediate, @checkpoint, @interrupt, %{@interrupt | fallback: :queue_next}, @immediate]},
    {"muse", [@checkpoint, @checkpoint, @interrupt, %{@interrupt | fallback: :queue_next}, @unsupported]},
    # Kimi is a registered OpenAI-compatible backend, not a synthetic profile.
    {"kimi", [@checkpoint, @checkpoint, {:error, :interrupt_not_supported}, %{@checkpoint | fallback: :queue_next}, @unsupported]},
    {"fake", [@checkpoint, @checkpoint, {:error, :interrupt_not_supported}, %{@checkpoint | fallback: :queue_next}, @unsupported]}
  ]
  @requests [{:auto, nil}, {:checkpoint, nil}, {:interrupt, nil}, {:interrupt, :queue_next}, {:immediate, nil}]
  @states [:working_active, :working_idle, :sleeping, :paused, :self_paused, :self_paused_pending, :working_pending]
  @rows (for {harness, deliveries} <- @profiles,
             {{requested, fallback}, delivery} <- Enum.zip(@requests, deliveries),
             entry_state <- @states do
           wake =
             case {entry_state, delivery} do
               {_, {:error, _}} -> nil
               {state, _} when state in [:paused, :self_paused_pending, :working_pending] -> false
               {state, _} when state in [:working_idle, :sleeping] -> true
               {_, %{priority: :now}} -> true
               _ -> false
             end

           %{harness: harness, requested: requested, fallback: fallback, entry_state: entry_state, expect: {delivery, wake}}
         end)

  test "delivery matrix: requested policy x registry harness x entry state" do
    mismatches =
      Enum.flat_map(@rows, fn row ->
        actual = observe(row)
        if actual == row.expect, do: [], else: [%{row: row, actual: actual}]
      end)

    assert mismatches == [], inspect(mismatches, pretty: true, limit: :infinity)
  end

  test "omitted policy uses checkpoint even on an immediate-capable harness" do
    row = %{harness: "claude-repl", requested: :omitted, fallback: nil, entry_state: :working_active}
    assert observe(row) == {@checkpoint, false}
  end

  test "R7-C1-F1: control flags follow the dispatched backend, not the running transport" do
    row = %{harness: "claude-repl", requested: :auto, fallback: nil, entry_state: :working_active, transport: "claude"}
    assert observe(row) == {@immediate, true}
  end

  test "no running entry rejects messages without enqueuing or waking" do
    state = %State{queue_store: AgentQueueStore.new()}
    assert {:reply, {:error, :no_running_agent}, ^state} = OperatorMessages.send_operator_message_call(state, "missing-r7", %{kind: :text, body: "x"})
    refute_received {:agent_queue_updated, "missing-r7", _, _}
  end

  defp observe(row) do
    identifier = "r7-matrix-#{System.unique_integer([:positive])}"
    state = state_for(row, identifier)
    :ok = ActiveTurns.put(identifier, "active")
    if row.entry_state == :working_idle, do: ActiveTurns.mark_closed(identifier, "active", :idle)

    try do
      send_and_observe(state, identifier, row)
    after
      ActiveTurns.mark_closed(identifier, "active", :test_cleanup)
    end
  end

  defp send_and_observe(state, identifier, row) do
    payload = %{kind: :text, body: "matrix text", fallback: row.fallback}
    payload = if row.requested == :omitted, do: payload, else: Map.put(payload, :delivery_policy, row.requested)

    case OperatorMessages.send_operator_message_call(state, identifier, payload) do
      {:reply, {:ok, item_id}, updated} ->
        assert_received {:agent_queue_updated, ^identifier, ^item_id, wake}
        [item] = AgentQueueStore.list_pending(updated.queue_store, identifier)
        assert item.id == item_id
        assert item.body == %{text: "matrix text"}
        {item.delivery, wake}

      {:reply, {:error, _} = error, updated} ->
        assert updated == state
        assert AgentQueueStore.list_pending(updated.queue_store, identifier) == []
        refute_received {:agent_queue_updated, ^identifier, _, _}
        {error, nil}
    end
  end

  defp state_for(row, identifier) do
    status = if row.entry_state in [:working_active, :working_idle, :working_pending], do: :working, else: :paused
    status = if row.entry_state == :sleeping, do: :sleeping, else: status

    control = %{
      status: status,
      can_interrupt: CodingAgent.can_interrupt?(row.harness),
      safe_checkpoints: CodingAgent.safe_checkpoints(row.harness),
      immediate_delivery: CodingAgent.immediate_delivery?(row.harness)
    }

    entry = %{identifier: identifier, issue: %Issue{id: identifier, identifier: identifier}, pid: self(), control: control, session_execution: %{backend: Map.get(row, :transport, row.harness)}}
    entry = if row.entry_state in [:self_paused, :self_paused_pending], do: Map.put(entry, :paused_reason, :agent_pause_request), else: entry
    state = %State{queue_store: AgentQueueStore.new(), running: %{identifier => entry}}
    if row.entry_state in [:self_paused_pending, :working_pending], do: pending_pause(state, identifier), else: state
  end

  defp pending_pause(state, identifier) do
    identity = %TrackerIdentity{status: :joinable, kind: :github, owner: "aiur-team", repository: "aiur", provider_id: identifier, identifier: "3464", reason: nil}
    attrs = %{request_id: "pause-r7", issue_id: identifier, tracker_identity: identity, action: :pause, generation: "r7", expected_status: :working, expected_version: 0, requester: :automatic}
    {:ok, _, lifecycle} = ControlLifecycle.request(state.control_lifecycle, attrs)
    entry = Map.put(state.running[identifier], :pending_pause_reason, %{request_id: "pause-r7", reason: :agent_pause_request})
    %{state | control_lifecycle: lifecycle, running: %{identifier => entry}}
  end
end

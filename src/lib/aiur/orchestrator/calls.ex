defmodule Aiur.Orchestrator.Calls do
  @moduledoc "Synchronous Orchestrator message routing; clause order follows the GenServer facade."
  alias Aiur.Orchestrator.{BuildQueueClaimProbe, GlobalPause, Interrupts, Lifecycle, Parking, PauseResume, PriorityControl, Slots, StatusReport}

  alias Aiur.Orchestrator.OperatorMessages, as: OM
  alias Aiur.Orchestrator.RemoteControlMode, as: RC

  @spec handle_call(term(), GenServer.from(), Aiur.Orchestrator.State.t()) :: tuple()
  def handle_call(:prepare_handoff_snapshot, _from, state), do: Aiur.Handoff.hold_dispatch(state)
  def handle_call(:cancel_handoff, _from, state), do: Aiur.Handoff.release_dispatch(state)
  def handle_call({:enqueue_event_digest, identifier, event}, _from, state), do: OM.enqueue_event_digest_call(state, identifier, event)
  def handle_call({:enqueue_event_digest, id, event, %{subscribed_to: subs}}, _from, state) when is_list(subs), do: OM.enqueue_event_digest_call(state, id, event, subscribed_to: subs)

  def handle_call({:enqueue_event_digest_batch, identifier, events}, _from, state)
      when is_binary(identifier) and is_list(events),
      do: OM.enqueue_event_digest_batch_call(state, identifier, events)

  def handle_call(:poll_status, _from, state), do: StatusReport.poll_status(state)

  def handle_call(:list_active_identifiers, _from, state),
    do: StatusReport.list_active_identifiers(state)

  def handle_call(:list_running_active_identifiers, _from, state),
    do: StatusReport.list_running_active_identifiers(state)

  def handle_call({:has_live_owner, identifier}, _from, state), do: StatusReport.has_live_owner(state, identifier)

  def handle_call({:build_queue_claim_status, ids}, _from, state) when is_list(ids) do
    {:reply, Map.new(ids, &{&1, BuildQueueClaimProbe.classify(state, &1)}), state}
  end

  def handle_call(:build_queue_next_set, _from, state), do: {:reply, BuildQueueClaimProbe.next_set(state), state}

  def handle_call(:status, _from, state), do: StatusReport.status(state)

  def handle_call(:status_with_capacity, _from, state), do: StatusReport.status_with_capacity(state)

  def handle_call(:snapshot, _from, state), do: StatusReport.snapshot(state)

  def handle_call(:fleet_view, _from, state), do: StatusReport.fleet_view_call(state)

  def handle_call(:request_refresh, _from, state) do
    state |> Lifecycle.request_refresh() |> publish_collapsed_poll()
  end

  def handle_call({:note_queued_demand, identifiers}, _from, state) when is_list(identifiers) do
    state |> Lifecycle.note_queued_demand(identifiers) |> publish_collapsed_poll()
  end

  def handle_call({:send_operator_message, issue_identifier, payload}, _from, state),
    do: OM.send_operator_message_call(state, issue_identifier, payload)

  def handle_call({:send_correlated_operator_message, issue_identifier, payload}, _from, state),
    do: OM.send_correlated_operator_message_call(state, issue_identifier, payload)

  def handle_call({:control_capabilities, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: OM.control_capabilities_call(state, issue_identifier)

  def handle_call({action, issue_identifier}, _from, state)
      when action in [:pause_agent, :park_agent] and is_binary(issue_identifier),
      do: if(action == :park_agent, do: Parking.park_agent_call(state, issue_identifier), else: PauseResume.pause_agent_call(state, issue_identifier))

  def handle_call({:pause_agent, %Aiur.TrackerIdentity{} = identity}, _from, state),
    do: PauseResume.pause_agent_call(state, identity)

  def handle_call({:pause_agent, _issue_identifier}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:request_control, issue_identifier, action, request_id}, _from, state)
      when is_binary(issue_identifier) and action in [:pause, :resume] and is_integer(request_id) and request_id > 0,
      do: PauseResume.request_control_call(state, issue_identifier, action, request_id)

  def handle_call({:request_control, _issue_identifier, _action, _request_id}, _from, state) do
    {:reply, {:error, :invalid_control_request}, state}
  end

  def handle_call({:interrupt_agent, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: Interrupts.interrupt_agent_call(state, issue_identifier)

  def handle_call({:interrupt_agent, _issue_identifier}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:pane_interrupt, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: Interrupts.pane_interrupt_call(state, issue_identifier)

  def handle_call({:pane_interrupt, _issue_identifier}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:pane_interrupt_by_pane_id, pane_id}, _from, state)
      when is_binary(pane_id),
      do: Interrupts.pane_interrupt_by_pane_id_call(state, pane_id)

  def handle_call({:tracker_control_result, action, identifier, stage, result}, _from, state),
    do: PauseResume.tracker_control_call(state, action, identifier, stage, result)

  def handle_call({:resume_agent, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: PauseResume.tracker_control_call(state, :resume, issue_identifier)

  def handle_call({:resume_agent, _issue_identifier}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:resume_agent_with_receipt, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: PauseResume.tracker_control_call(state, :resume_with_receipt, issue_identifier)

  def handle_call({:resume_agent_with_receipt, _issue_identifier}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:prioritize_agent, issue_identifier}, from, state) when is_binary(issue_identifier),
    do: PriorityControl.prioritize_agent_call(state, issue_identifier, from: from)

  def handle_call({:prioritize_agent, _issue_identifier}, _from, state),
    do: {:reply, {:error, :invalid_identifier}, state}

  def handle_call({:deprioritize_agent, issue_identifier}, from, state) when is_binary(issue_identifier),
    do: PriorityControl.deprioritize_agent_call(state, issue_identifier, from: from)

  def handle_call({:deprioritize_agent, _issue_identifier}, _from, state),
    do: {:reply, {:error, :invalid_identifier}, state}

  def handle_call({:reset_dispatch_budget, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: PauseResume.tracker_control_call(state, :reset_budget, issue_identifier)

  def handle_call({:reset_dispatch_budget, _issue_identifier}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:control_lifecycle, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: PauseResume.control_lifecycle_call(state, issue_identifier)

  def handle_call({:control_lifecycle, _issue_identifier}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:set_remote_control, issue_identifier, on?}, from, state)
      when is_binary(issue_identifier) and is_boolean(on?),
      do: RC.set_remote_control_call(state, issue_identifier, on?, from: from)

  def handle_call({:set_remote_control, _issue_identifier, _on?}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:ensure_remote_control_trust, workspace}, from, state)
      when is_binary(workspace),
      do: RC.ensure_remote_control_trust_call(state, workspace, from)

  def handle_call(:max_concurrent_agents, _from, state),
    do: Slots.max_concurrent_agents_call(state)

  def handle_call({:adjust_max_concurrent_agents, delta}, _from, state)
      when is_integer(delta),
      do: Slots.adjust_max_concurrent_agents_call(state, delta)

  def handle_call({:set_max_concurrent_agents, n}, _from, state)
      when is_integer(n) and n > 0,
      do: Slots.set_max_concurrent_agents_call(state, n)

  def handle_call(:globally_paused?, _from, state),
    do: GlobalPause.globally_paused_call(state)

  def handle_call(:global_pause_status, _from, state),
    do: {:reply, GlobalPause.global_pause_status(state), state}

  def handle_call({:set_global_pause, on?}, _from, state)
      when is_boolean(on?),
      do: GlobalPause.set_global_pause_call(state, on?)

  def handle_call({:set_global_pause, on?, source}, _from, state)
      when is_boolean(on?) and is_binary(source),
      do: GlobalPause.set_global_pause_call(state, on?, source)

  def handle_call({:operator_message_status, item_id}, _from, state)
      when is_integer(item_id),
      do: OM.operator_message_status_call(state, item_id)

  def handle_call({:lookup_operator_message, {kind, key} = lookup}, _from, state)
      when kind in [:message_id, :action_id] and is_binary(key),
      do: OM.lookup_operator_message_call(state, lookup)

  def handle_call({:lookup_operator_message, {:message_id, key} = lookup, %{target: _, text: text} = expected}, _from, state)
      when is_binary(key) and is_binary(text),
      do: OM.lookup_operator_message_call(state, lookup, expected)

  def handle_call({:claim_next_queue_item, id}, _from, state) when is_binary(id), do: Aiur.Handoff.claim_or_empty(state, fn -> OM.claim_next_queue_item_call(state, id) end)

  def handle_call({:claim_next_checkpoint_queue_item, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: Aiur.Handoff.claim_or_empty(state, fn -> OM.claim_next_checkpoint_queue_item_call(state, issue_identifier) end)

  def handle_call({:claim_blocker_critical_events_digest, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: Aiur.Handoff.claim_or_empty(state, fn -> OM.claim_blocker_critical_events_digest_call(state, issue_identifier) end)

  def handle_call({:claim_next_operator_queue_item, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: Aiur.Handoff.claim_or_empty(state, fn -> OM.claim_next_operator_queue_item_call(state, issue_identifier) end)

  def handle_call({:claim_operator_response, identifier, command}, _from, state)
      when is_binary(identifier) and is_binary(command) and command != "",
      do: Aiur.Handoff.claim_or_empty(state, fn -> OM.claim_operator_response_call(state, identifier, command) end)

  def handle_call({:mark_queue_item_consumed, item_id}, _from, state)
      when is_integer(item_id),
      do: OM.mark_queue_item_consumed_call(state, item_id)

  def handle_call({:restore_queue_item_pending, item_id}, _from, state)
      when is_integer(item_id),
      do: OM.restore_queue_item_pending_call(state, item_id)

  def handle_call({:mark_queue_item_failed, item_id, reason}, _from, state)
      when is_integer(item_id),
      do: OM.mark_queue_item_failed_call(state, item_id, reason)

  def handle_call(
        {:acknowledge_queue_item_delivery, item_id, provider_metadata},
        _from,
        state
      )
      when is_integer(item_id) and is_map(provider_metadata),
      do:
        OM.acknowledge_queue_item_delivery_call(
          state,
          item_id,
          provider_metadata
        )

  def handle_call({:consume_delivered_queue_items, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: OM.consume_delivered_queue_items_call(state, issue_identifier)

  def handle_call({:restore_delivered_queue_items, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: OM.restore_delivered_queue_items_call(state, issue_identifier)

  def handle_call({:fail_delivered_queue_items, issue_identifier, reason}, _from, state)
      when is_binary(issue_identifier),
      do: OM.fail_delivered_queue_items_call(state, issue_identifier, reason)

  # Republish a collapsed timer wake so status shows its new countdown (#2640).
  # Coalesced requests do not change the countdown.
  defp publish_collapsed_poll({:reply, %{coalesced: false} = result, state}) do
    StatusReport.notify_dashboard(state)
    {:reply, result, state}
  end

  defp publish_collapsed_poll(reply), do: reply
end

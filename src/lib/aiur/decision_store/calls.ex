defmodule Aiur.DecisionStore.Calls do
  @moduledoc false

  alias Aiur.DecisionQuery.Params, as: DecisionQueryParams
  alias Aiur.DecisionStore.AgentLifecycle
  alias Aiur.DecisionStore.Answers
  alias Aiur.DecisionStore.AppendRecovery
  alias Aiur.DecisionStore.Audit
  alias Aiur.DecisionStore.Dispatch
  alias Aiur.DecisionStore.Enrichment
  alias Aiur.DecisionStore.Index
  alias Aiur.DecisionStore.Persistence
  alias Aiur.DecisionStore.Requests
  alias Aiur.DecisionStore.RetainedSnapshot
  alias Aiur.DecisionStore.Retry
  alias Aiur.DecisionStore.Revisions
  alias Aiur.DecisionStore.Transport
  alias Aiur.DecisionStore.Withdrawals

  @spec handle_call(term(), term(), term()) :: term()
  def handle_call({:request, _payload, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({operation, _payload, _opts}, _from, %{writable?: false} = state)
      when operation in [:project_attention, :enrich_attention] do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:request, payload, opts}, _from, state) do
    Requests.handle_request(payload, opts, state)
  end

  def handle_call({:project_attention, payload, opts}, _from, state) do
    Enrichment.handle_attention_projection(payload, opts, state)
  end

  def handle_call({:enrich_attention, payload, opts}, _from, state) do
    Enrichment.handle_attention_enrichment(payload, opts, state)
  end

  def handle_call({:enrich, _decision_id, _patch, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:enrich, decision_id, patch, opts}, _from, state) do
    Enrichment.handle_enrichment(decision_id, patch, opts, state)
  end

  def handle_call({:answer, _decision_id, _payload, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:answer, decision_id, payload, opts}, _from, state) do
    Answers.handle_answer(decision_id, payload, opts, state)
  end

  def handle_call({:escalate_executor_command, _decision_id, _payload}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:escalate_executor_command, decision_id, payload}, _from, state) do
    Requests.handle_executor_escalation(decision_id, payload, state)
  end

  def handle_call({:dismiss, _decision_id, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:dismiss, decision_id, opts}, _from, state) do
    Withdrawals.handle_dismiss(decision_id, opts, state)
  end

  def handle_call({:defer, _decision_id, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:defer, decision_id, opts}, _from, state) do
    Withdrawals.handle_defer(decision_id, opts, state)
  end

  def handle_call({:expire, _decision_id, _reason_class, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:expire, decision_id, reason_class, opts}, _from, state) do
    Withdrawals.handle_expire(decision_id, reason_class, opts, state)
  end

  def handle_call({:moot, _decision_id, _payload, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:moot, decision_id, payload, opts}, _from, state) do
    Withdrawals.handle_moot(decision_id, payload, opts, state)
  end

  def handle_call({:supersede, _decision_id, _payload, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:supersede, decision_id, payload, opts}, _from, state) do
    Revisions.handle_supersede(decision_id, payload, opts, state)
  end

  def handle_call({:revise, _decision_id, _payload, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:revise, decision_id, payload, opts}, _from, state) do
    Revisions.handle_revision(decision_id, payload, opts, state)
  end

  def handle_call({:handle_revision_follow_up, _decision_id, _action_id, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:handle_revision_follow_up, decision_id, action_id, opts}, _from, state) do
    Revisions.do_handle_revision_follow_up(decision_id, action_id, opts, state)
  end

  def handle_call({:retry_dispatch, _decision_id, _action_id}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:retry_dispatch, decision_id, action_id}, _from, state) do
    case Retry.validate_explicit_retry(state, decision_id, action_id) do
      {:ok, :already_dispatching} ->
        {:reply, {:ok, :already_dispatching}, state}

      {:ok, decision} ->
        if Retry.lifecycle_append_failed?(state, action_id) do
          AppendRecovery.schedule_append_reconciliation(state, decision, action_id, 0)
        else
          Dispatch.schedule_dispatch(state, decision, true, 0)
        end

        {:reply, {:ok, :scheduled}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  def handle_call({:transport_transition, _type, _item, _reason}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:validate_delivery, _item}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:validate_delivery, item}, _from, state) do
    {reply, next_state} = Transport.validate_and_hand_off(state, item)
    {:reply, reply, next_state}
  end

  def handle_call({:transport_transition, type, item, reason}, _from, state) do
    {reply, next_state} = Transport.apply_transport_transition(state, type, item, reason)
    {:reply, reply, next_state}
  end

  def handle_call({:agent_lifecycle, _type, _payload, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:agent_lifecycle, type, payload, opts}, _from, state) do
    {reply, next_state} = AgentLifecycle.apply_agent_lifecycle(state, type, payload, opts)
    {:reply, reply, next_state}
  end

  def handle_call({:get, decision_id}, _from, state) do
    case Map.fetch(state.current, decision_id) do
      {:ok, decision} -> {:reply, {:ok, decision}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state.current), state}
  end

  def handle_call({:retained_lookup, decision_id}, _from, state) do
    {:reply, RetainedSnapshot.lookup(state.current, state.health, decision_id), state}
  end

  def handle_call({:retained_query, query}, _from, state) do
    {ordering, query} = Map.pop(query, :ordering, :audit)

    reply =
      case DecisionQueryParams.parse(query) do
        {:ok, normalized} ->
          RetainedSnapshot.query(
            state.current,
            state.retained_index,
            state.health,
            Map.put(normalized, :ordering, ordering)
          )

        {:error, _reason} ->
          {:error, :invalid_query}
      end

    {:reply, reply, state}
  end

  def handle_call({:retained_legacy_page, query, offset, limit}, _from, state) do
    reply =
      with :ok <- Index.valid_legacy_page?(offset, limit),
           {:ok, normalized} <- DecisionQueryParams.parse(Index.legacy_query_params(query)),
           true <- is_nil(normalized.cursor) do
        RetainedSnapshot.legacy_page(
          state.current,
          state.retained_index,
          state.health,
          Map.merge(normalized, %{limit: limit, ordering: :current}),
          offset
        )
      else
        _invalid -> {:error, :invalid_query}
      end

    {:reply, reply, state}
  end

  def handle_call(:retained_counts, _from, state) do
    {:reply, RetainedSnapshot.counts(state.retained_index, state.health), state}
  end

  def handle_call(:blocked_ticket_ids, _from, state) do
    if Withdrawals.readable?(state.health) do
      ids =
        state.current
        |> Map.values()
        |> Enum.filter(&Withdrawals.open_blocking_command?/1)
        |> Enum.map(& &1.ticket.identifier)
        |> MapSet.new()

      {:reply, {:ok, ids}, state}
    else
      {:reply, {:error, :store_unavailable}, state}
    end
  end

  def handle_call({:open_blocking_decision_ids, ticket_identifiers}, _from, state) do
    if Withdrawals.readable?(state.health) do
      wanted = MapSet.new(ticket_identifiers)

      ids =
        state.current
        |> Map.values()
        |> Enum.filter(&(Withdrawals.open_blocking_command?(&1) and MapSet.member?(wanted, &1.ticket.identifier)))
        |> Enum.map(& &1.decision_id)
        |> Enum.sort()

      {:reply, {:ok, ids}, state}
    else
      {:reply, {:error, :store_unavailable}, state}
    end
  end

  def handle_call({:nonblocking_question_pause, ticket_identifier}, _from, state) do
    if Withdrawals.readable?(state.health) do
      decisions = Enum.filter(Map.values(state.current), &(&1.ticket.identifier == ticket_identifier))
      suppress? = Enum.any?(decisions, &Withdrawals.open_nonblocking_agent_question?/1) and not Enum.any?(decisions, &Withdrawals.open_blocking_command?/1)
      {:reply, {:ok, suppress?}, state}
    else
      {:reply, {:error, :store_unavailable}, state}
    end
  end

  def handle_call({:recent_decisions, limit}, _from, state) do
    decisions = Index.take_indexed_decisions(state.decision_index, state.current, limit)
    {:reply, decisions, state}
  end

  def handle_call({:history, decision_id}, _from, state) do
    case Map.fetch(state.history, decision_id) do
      {:ok, history} -> {:reply, {:ok, Enum.reverse(history)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:all_history, _from, state) do
    {:reply, Index.reverse_histories(state.history), state}
  end

  def handle_call(:all_audit_history, _from, state) do
    {:reply, state.audit_history, state}
  end

  def handle_call({:recent_audit_history, limit}, _from, state) do
    records = Enum.take(state.recent_audit, limit)
    {:reply, Audit.recent_audit_payload(state, records), state}
  end

  def handle_call({:audit_history, decision_id}, _from, state) do
    case Map.fetch(state.audit_history, decision_id) do
      {:ok, history} -> {:reply, {:ok, history}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:health, _from, state) do
    {:reply, state.health, state}
  end

  @spec handle_cast(term(), term()) :: term()
  def handle_cast({:transport_transition, _type, _item, _reason}, %{writable?: false} = state) do
    {:noreply, state}
  end

  def handle_cast({:transport_transition, type, item, reason}, state) do
    {_reply, next_state} = Transport.apply_transport_transition(state, type, item, reason)
    {:noreply, next_state}
  end

  def handle_cast({:transport_transitions, _type, _items, _reason}, %{writable?: false} = state) do
    {:noreply, state}
  end

  def handle_cast({:transport_transitions, type, items, reason}, state) do
    {:noreply, Transport.apply_transport_transitions(state, type, items, reason)}
  end

  def handle_cast({:deliver_pending_answers, _ticket_identifier}, %{writable?: false} = state) do
    {:noreply, state}
  end

  def handle_cast({:deliver_pending_answers, ticket_identifier}, state) do
    {:noreply, Retry.schedule_pending_answer_delivery(state, ticket_identifier)}
  end
end

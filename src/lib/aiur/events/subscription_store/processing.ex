defmodule Aiur.Events.SubscriptionStore.Processing do
  @moduledoc false
  # aiur:event-bus-boundary-member

  # Runs synchronously in the store process; retries and buffer draining retain
  # the same mailbox owner and ordering.
  require Logger

  alias Aiur.Events.{Exchange, HistoryStore, Trace, UniversalSubscriptions}
  alias Aiur.Events.SubscriptionStore.Persistence

  @max_stall_attempts 3
  @stall_base_retry_ms 1_000

  @spec handle_info(term(), map()) :: {:noreply, map()}
  def handle_info({:event, event}, state) do
    # A `system.config.base_branch.changed` event is the fleet-wide
    # announcement that `tracker.base_branch` moved. Reconcile this ticket's
    # own `base_branch:auto` subscription inline (direct state mutation, never
    # a self-call, so no deadlock) so a running agent stops listening on the
    # retired branch's push topic and starts hearing the new one immediately —
    # without waiting for the next `attach`.
    state = maybe_reconcile_base_branch(state, event)

    event_id = Map.get(event, :id) || Map.get(event, "id")
    cursor = state.last_seen_event_id || 0

    cond do
      not is_integer(event_id) or event_id <= cursor ->
        Logger.debug("SubscriptionStore(#{state.identifier}): dropping event #{inspect(event_id)} at cursor #{cursor}")
        {:noreply, state}

      state.stall != nil ->
        # Ordering: while an earlier event is stalled, hold later events in a
        # buffer instead of delivering them past the stall. They are not
        # enqueued or recorded yet, so a restart during the stall replays
        # them (and the stalled event) exactly once from the publisher log —
        # no loss, and no duplicate delivery past a held cursor.
        {:noreply, buffer_event(state, event_id, event)}

      true ->
        {:noreply, process_new_event(state, event, event_id, cursor)}
    end
  end

  def handle_info({:retry_stalled}, %{stall: nil} = state), do: {:noreply, state}

  def handle_info({:retry_stalled}, state) do
    %{event: event, event_id: event_id, attempt: attempt} = state.stall
    topic = Map.get(event, :topic) || Map.get(event, "topic") || "(unknown)"

    new_state =
      case enqueue_event(state, event) do
        :ok ->
          HistoryStore.record(state.identifier, :consumed, event)
          Trace.trace(:receive, topic, id: event_id, identifier: state.identifier, body: event)
          resolve_stall(state, event_id)

        {:error, reason} ->
          if attempt >= @max_stall_attempts or error_kind(reason) == :permanent do
            state.delivery.dead_letter(state.identifier, event_id, topic, reason, attempt)
            resolve_stall(state, event_id)
          else
            next_attempt = attempt + 1
            Process.send_after(self(), {:retry_stalled}, @stall_base_retry_ms * next_attempt)
            %{state | stall: %{state.stall | attempt: next_attempt}}
          end
      end

    {:noreply, new_state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp process_new_event(state, event, event_id, cursor) do
    topic = Map.get(event, :topic) || Map.get(event, "topic") || "(unknown)"

    case enqueue_event(state, event) do
      :ok ->
        HistoryStore.record(state.identifier, :consumed, event)
        Trace.trace(:receive, topic, id: event_id, identifier: state.identifier, body: event)
        advance_cursor_inline(state, event_id)

      {:error, reason} ->
        case error_kind(reason) do
          :permanent ->
            state.delivery.dead_letter(state.identifier, event_id, topic, reason, 1)
            advance_cursor_inline(state, event_id)

          :transient ->
            Logger.warning(
              "SubscriptionStore(#{state.identifier}): enqueue failed for event #{inspect(event_id)} " <>
                "on topic #{topic}: #{inspect(reason)}; cursor held at #{cursor}, scheduling retry"
            )

            Process.send_after(self(), {:retry_stalled}, @stall_base_retry_ms)
            %{state | stall: %{event: event, event_id: event_id, attempt: 1}}
        end
    end
  end

  # Buffer an event received while an earlier event is stalled. We do not
  # enqueue or record it yet — the cursor is deliberately held, so a restart
  # during the stall replays it exactly once. `resolve_stall/2` re-delivers
  # buffered events through the normal path, in order, once the stall lifts.
  defp buffer_event(state, event_id, event) do
    %{state | stalled_buffer: state.stalled_buffer ++ [{event_id, event}]}
  end

  # Drain before returning to the mailbox, where newer events may already wait.
  defp resolve_stall(state, event_id) do
    new_state = advance_cursor_inline(%{state | stall: nil, stalled_buffer: []}, event_id)

    state.stalled_buffer
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(new_state, fn {_id, event}, acc ->
      {:noreply, next} = handle_info({:event, event}, acc)
      next
    end)
  end

  defp error_kind(:no_orchestrator), do: :transient
  defp error_kind({:exit, {:timeout, _}}), do: :transient
  defp error_kind({:exit, _}), do: :transient
  defp error_kind({:raised, _}), do: :permanent
  defp error_kind(_), do: :transient

  defp advance_cursor_inline(state, event_id) when is_integer(event_id) do
    new_cursor = max(state.last_seen_event_id || 0, event_id)
    new_state = %{state | last_seen_event_id: new_cursor}
    _ = Persistence.persist(new_state)
    new_state
  end

  defp advance_cursor_inline(state, _), do: state

  defp maybe_reconcile_base_branch(state, %{topic: topic}) when is_binary(topic) do
    if topic == "system.config.base_branch.changed" do
      reconcile_base_branch_auto(state)
    else
      state
    end
  end

  defp maybe_reconcile_base_branch(state, _event), do: state

  # Runs entirely inside this GenServer — never calls back into
  # `SubscriptionStore.remove_subscription/add_subscription` (a self-call would
  # deadlock). Diffing against the previous list keeps the Exchange bindings
  # exact and the persisted state authoritative. Any failure leaves the prior
  # subscriptions untouched so a transient config hiccup cannot break a running
  # agent's feed.
  defp reconcile_base_branch_auto(state) do
    desired = UniversalSubscriptions.reconcile_subscribed_to(state.subscribed_to)

    reconcile_exchange_bindings(state.subscribed_to, desired)
    new_state = %{state | subscribed_to: desired}
    _ = Persistence.persist(new_state)
    new_state
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  defp reconcile_exchange_bindings(previous, desired) do
    previous_topics = Enum.map(previous, &Map.get(&1, "topic"))
    desired_topics = Enum.map(desired, &Map.get(&1, "topic"))

    for topic <- previous_topics -- desired_topics do
      _ = Persistence.safe_unsubscribe(topic)
    end

    for topic <- desired_topics -- previous_topics do
      try do
        :ok = Exchange.subscribe(topic)
      rescue
        error ->
          Logger.warning(
            "SubscriptionStore(#{inspect(self())}) failed to subscribe after base reconcile " <>
              topic <> ": " <> Exception.message(error)
          )
      end
    end

    :ok
  end

  defp enqueue_event(state, event) do
    case :persistent_term.get({Aiur.Events.SubscriptionStore, :enqueue_fn}, nil) do
      fun when is_function(fun, 2) -> call_enqueue_fn(fun, state.identifier, event)
      _ -> call_enqueue_fn(fn id, event -> state.delivery.enqueue(id, event, %{subscribed_to: state.subscribed_to}) end, state.identifier, event)
    end
  end

  defp call_enqueue_fn(fun, identifier, event) do
    case fun.(identifier, event) do
      :ok -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_return, other}}
    end
  rescue
    e -> {:error, {:raised, e}}
  end
end

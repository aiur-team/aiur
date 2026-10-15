defmodule Aiur.DecisionStore.AppendRecovery do
  @moduledoc false

  require Logger

  alias Aiur.DecisionStore.Dispatch
  alias Aiur.DecisionStore.Persistence
  alias Aiur.Signal

  @spec recover_background_append(term(), term(), term(), term(), term()) :: term()
  def recover_background_append(state, decision, action_id, type, reason) do
    state
    |> Persistence.journal_failure_state(reason)
    |> lifecycle_append_failed(decision, action_id, type, reason)
    |> schedule_append_retry(decision, action_id)
  end

  defp lifecycle_append_failed(state, decision, action_id, type, reason) do
    Logger.error("aiur_decision_store phase=lifecycle_append_failed type=#{type} reason=#{inspect(reason)}")

    failures = Map.get(state, :lifecycle_append_failures, MapSet.new())

    unless MapSet.member?(failures, action_id) do
      _ =
        Signal.agent_alert(
          lifecycle_append_failure_topic(decision, action_id),
          "Decision delivery persistence is temporarily unavailable for #{decision.decision_id}.",
          issue: decision.ticket.identifier,
          reason:
            "Decision #{decision.decision_id} action #{action_id} could not record #{type}; " <>
              "retry is bounded; journal uncertainty holds further writes.",
          needs_attention: true,
          severity: "warning"
        )
    end

    %{state | lifecycle_append_failures: MapSet.put(failures, action_id)}
  end

  defp schedule_append_retry(state, decision, action_id) do
    retry_counts = Map.get(state, :append_retry_counts, %{})
    retry_count = Map.get(retry_counts, action_id, 0)
    next_state = %{state | append_retry_counts: Map.put(retry_counts, action_id, retry_count + 1)}

    case Enum.at(state.retry_delays_ms, retry_count) do
      delay when is_integer(delay) and delay >= 0 ->
        schedule_append_reconciliation(state, decision, action_id, delay)
        next_state

      _other ->
        next_state
    end
  end

  @spec resolve_lifecycle_append_failure(term(), term(), term()) :: term()
  def resolve_lifecycle_append_failure(state, decision, action_id) when is_binary(action_id) do
    failures = Map.get(state, :lifecycle_append_failures, MapSet.new())

    if MapSet.member?(failures, action_id) do
      _ =
        Signal.agent_alert(
          lifecycle_append_failure_topic(decision, action_id) <> ".resolved",
          "Decision delivery persistence recovered for #{decision.decision_id}.",
          issue: decision.ticket.identifier,
          reason:
            "Decision #{decision.decision_id} action #{action_id} " <>
              "resumed durable lifecycle recording.",
          needs_attention: false,
          severity: "info"
        )

      %{
        state
        | lifecycle_append_failures: MapSet.delete(failures, action_id),
          append_retry_counts: Map.delete(Map.get(state, :append_retry_counts, %{}), action_id)
      }
    else
      state
    end
  end

  @spec schedule_append_reconciliation(term(), term(), term(), term()) :: term()
  def schedule_append_reconciliation(state, decision, action_id, delay_ms) do
    Dispatch.schedule_dispatch_work(state, {:reconcile_lifecycle_append, Dispatch.dispatch_fence(decision), action_id}, delay_ms)
  end

  defp lifecycle_append_failure_topic(decision, action_id) do
    action_slug = String.replace(action_id, "_", "-")
    "ticket.#{decision.ticket.identifier}.agent.attention.decision-lifecycle-persistence-#{action_slug}"
  end

  @spec retry_follow_up_append(term(), term(), term(), term(), term()) :: term()
  def retry_follow_up_append(state, decision, type, data, reason) do
    key = {decision.decision_id, type, data.action_id}
    pending = %{type: type, data: data, reason: reason}
    state = lifecycle_append_failed(state, decision, data.action_id, type, reason)
    state = %{state | writable?: false, health: {:lifecycle_append_failed, type, reason}, follow_up_append_retries: Map.put(state.follow_up_append_retries, key, pending)}
    count = Map.get(state.append_retry_counts, key, 0)

    case Enum.at(state.retry_delays_ms, count) do
      delay when is_integer(delay) and delay >= 0 -> Dispatch.schedule_dispatch_work(state, {:retry_follow_up_append, key}, delay)
      _other -> :ok
    end

    %{state | append_retry_counts: Map.put(state.append_retry_counts, key, count + 1)}
  end

  @spec retry_pending_follow_up(term(), term()) :: term()
  def retry_pending_follow_up(%{health: {:lifecycle_append_failed, _, _}} = state, {decision_id, _type, _action_id} = key) do
    case Map.fetch(state.follow_up_append_retries, key) do
      :error ->
        state

      {:ok, pending} ->
        decision = Map.fetch!(state.current, decision_id)

        case append_pending_follow_up(state, decision, pending) do
          {:ok, next_state, updated, event} -> complete_follow_up_retry(next_state, updated, event, key, pending)
          {:error, reason} -> retry_follow_up_append(state, decision, pending.type, pending.data, reason)
        end
    end
  end

  def retry_pending_follow_up(state, _key), do: state

  defp append_pending_follow_up(state, decision, %{reason: {:journal_ambiguous, event, _reason}}) do
    with {:ok, updated} <- Persistence.validate_transition(decision, event),
         :ok <- Persistence.reconcile_append(state, event) do
      next_state = Persistence.apply_appended_event(state, decision, updated, event)
      {:ok, next_state, updated, event}
    end
  end

  defp append_pending_follow_up(state, decision, pending) do
    with :ok <- Persistence.verify_journal(state) do
      append_verified_follow_up(state, decision, pending)
    end
  end

  defp append_verified_follow_up(state, decision, pending) do
    with {:ok, next_state, updated, event} <- Persistence.build_and_append_event(pending.type, decision, pending.data, DateTime.utc_now(), %{state | writable?: true}) do
      {:ok, %{next_state | writable?: false}, updated, event}
    end
  end

  defp complete_follow_up_retry(state, decision, event, key, pending) do
    remaining = Map.delete(state.follow_up_append_retries, key)
    recovered? = map_size(remaining) == 0 and match?({:lifecycle_append_failed, _, _}, state.health)
    state = %{state | follow_up_append_retries: remaining, append_retry_counts: Map.delete(state.append_retry_counts, key)}
    state = if recovered?, do: %{state | writable?: true, health: :writable}, else: state
    state = Persistence.repair_and_notify_lifecycle(state, [{decision, event}])

    state =
      case pending.type do
        :follow_up_required ->
          Dispatch.maybe_schedule_revision_follow_up_projection(state, decision, pending.data.action_id)

        :follow_up_handled ->
          state
          |> Dispatch.maybe_schedule_revision_follow_up_resolution(decision, pending.data.action_id)
          |> Dispatch.maybe_schedule_after_answer(decision, false)
      end

    release_journal_work(state)
  end

  defp release_journal_work(%{writable?: true} = state) do
    state.held_journal_work |> Enum.reverse() |> Enum.each(&send(self(), &1))
    %{state | held_journal_work: []}
  end

  defp release_journal_work(state), do: state
end

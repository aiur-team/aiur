defmodule Aiur.DecisionStore.Retry do
  @moduledoc false

  require Logger

  alias Aiur.Decision
  alias Aiur.DecisionAnswer
  alias Aiur.DecisionStore.Answers
  alias Aiur.DecisionStore.Dispatch
  alias Aiur.DecisionStore.FailureAttention
  alias Aiur.Signal

  # One retry ladder for every answered Decision, revision or not. A target
  # that is momentarily unreachable — paused, restarting, or refused a wake
  # because the fleet is at its active cap — is a transient fault: the answer
  # is already durable and the agent is still waiting on it. Splitting the
  # ladder left a *first* answer with exactly two retryable classes, so a
  # delivery that failed `target_agent_unavailable` was recorded `failed` and
  # never retried — and, being non-actionable below, never raised either. The
  # answer was silently dropped and only an operator noticing a stuck agent
  # found it (#2558).
  # Dispatch failures whose caller timed out: the Orchestrator may still have
  # queued the item (#2717).
  @timeout_failure_classes ["orchestrator_timeout", "decision_dispatch_timeout"]
  @transient_failure_classes [
    "orchestrator_unavailable",
    "orchestrator_timeout",
    "target_agent_unavailable",
    "target_revalidation_failed"
  ]

  @spec maybe_retry_transient(term(), term(), term(), term()) :: term()
  def maybe_retry_transient(state, decision, action_id, reason_class) do
    if decision.active_action_id == action_id and transient_failure?(decision, reason_class) do
      schedule_transient_retry(state, decision, action_id)
    else
      state
    end
  end

  defp schedule_transient_retry(state, decision, action_id) do
    retry_count = Map.get(state.retry_counts, action_id, 0)
    next_state = %{state | retry_counts: Map.put(state.retry_counts, action_id, retry_count + 1)}

    case Enum.at(state.retry_delays_ms, retry_count) do
      delay when is_integer(delay) and delay >= 0 ->
        Dispatch.schedule_dispatch(state, decision, false, delay)
        next_state

      _exhausted ->
        emit_retry_exhausted_attention(decision, action_id, retry_count)
        next_state
    end
  end

  # The bounded ladder is the only automatic recovery an answered Decision
  # gets. Once it is spent the answer really is stuck behind an unreachable
  # target, so it must be raised even when its failure class is otherwise
  # suppressed as non-actionable — which is exactly the case that lost an
  # answer with no operator-visible trace at all (#2558). Emitted once per
  # action, from the exhaustion branch only, so a saturated fleet retrying
  # many decisions cannot storm the attention feed; it lands *after*
  # `project_delivery_attention/4` has already run for this failure, so the
  # raise supersedes any `.resolved` clear that branch wrote.
  defp emit_retry_exhausted_attention(decision, action_id, attempts) do
    _ =
      Signal.agent_alert(
        FailureAttention.failure_attention_topic(decision),
        "Decision answer delivery gave up for #{decision.decision_id} after #{attempts} automatic retries.",
        issue: decision.ticket.identifier,
        reason:
          "Decision #{decision.decision_id} action #{action_id} exhausted its bounded delivery " <>
            "retries; #{exhausted_outcome(decision)}",
        needs_attention: true,
        severity: "warning"
      )

    :ok
  end

  # A ladder that ended on a timeout does not know if the item was queued
  # (#2717). The alert says so, and the delivery gate still adopts a late item.
  defp exhausted_outcome(decision) do
    if FailureAttention.outcome_unknown_pending?(decision),
      do: "the Orchestrator did not answer in time, so the answer may still be queued. Retry is safe: it cannot queue a second copy.",
      else: "the answer is recorded but undelivered and needs an operator retry."
  end

  defp transient_failure?(%Decision{}, reason_class), do: reason_class in @transient_failure_classes

  @spec dispatch_failure_class(term()) :: term()
  def dispatch_failure_class(:unavailable), do: "orchestrator_unavailable"
  def dispatch_failure_class(:timeout), do: "orchestrator_timeout"
  def dispatch_failure_class({:outcome_unknown, _info}), do: "orchestrator_timeout"
  def dispatch_failure_class({:not_queued, :timeout}), do: "orchestrator_timeout"
  def dispatch_failure_class(:no_running_agent), do: "target_agent_unavailable"
  # A wake refused because the fleet is at its active cap is the same fault as
  # a restarting agent — the target cannot take the answer *right now* — so it
  # rides the same bounded ladder instead of falling through to the opaque,
  # terminal `dispatch_rejected` (#2558).
  def dispatch_failure_class(:max_concurrent_agents_reached), do: "target_agent_unavailable"
  def dispatch_failure_class(:task_unavailable), do: "dispatch_task_unavailable"
  def dispatch_failure_class(:dispatcher_crashed), do: "dispatcher_crashed"
  def dispatch_failure_class(:delivery_target_unbound), do: "delivery_target_unbound"
  def dispatch_failure_class(:decision_dispatch_overloaded), do: "decision_dispatch_overloaded"
  def dispatch_failure_class(:decision_dispatch_unavailable), do: "decision_dispatch_unavailable"
  def dispatch_failure_class(:decision_dispatch_timeout), do: "decision_dispatch_timeout"
  def dispatch_failure_class(:decision_dispatch_coordinator_exit), do: "decision_dispatch_coordinator_exit"

  def dispatch_failure_class({:decision_dispatch_task_exit, _reason}),
    do: "decision_dispatch_task_exit"

  def dispatch_failure_class({:decision_dispatch_task_start_failed, _reason}),
    do: "decision_dispatch_task_start_failed"

  def dispatch_failure_class({:target_revalidation_failed, _reason}), do: "target_revalidation_failed"
  def dispatch_failure_class(_reason), do: "dispatch_rejected"

  # When the newest attempt timed out with no queue item on record, a queue
  # item for this action can only be its late item. If the delivery gate
  # refused and failed that item, the retry restores it instead of replaying
  # the failed copy, so the answer is never stranded (#2717). Older builds
  # recorded such a timeout as a failure with a timeout class.
  @spec orphan_recovery?(term()) :: term()
  def orphan_recovery?(decision) do
    case List.last(Decision.active_dispatch_attempts(decision)) do
      %{queue_item_id: nil, status: :unknown} -> true
      %{queue_item_id: nil, status: :failed, failure_reason_class: class} -> class in @timeout_failure_classes
      _other -> false
    end
  end

  @spec next_attempt_id(term()) :: term()
  def next_attempt_id(decision) do
    active_answer = Decision.active_answer(decision)
    "#{active_answer.action_id}:#{length(Decision.active_dispatch_attempts(decision)) + 1}"
  end

  @spec dispatch_allowed?(term(), term(), term()) :: term()
  def dispatch_allowed?(decision, retry_failed?, :normal), do: dispatchable?(decision, retry_failed?)
  def dispatch_allowed?(decision, _retry_failed?, :reconcile_queue), do: queue_reconcilable?(decision)

  def dispatch_allowed?(%Decision{decision_status: status}, _retry_failed?, :recover_append),
    do: status not in [:resolved, :moot]

  @spec queue_reconcilable?(term()) :: term()
  def queue_reconcilable?(%Decision{decision_status: :decided} = decision) do
    attempts = Decision.active_dispatch_attempts(decision)
    match?(%{status: status} when status in [:queued, :restored], List.last(attempts))
  end

  def queue_reconcilable?(%Decision{}), do: false

  @spec decision_for_dispatch(term(), term()) :: term()
  def decision_for_dispatch(state, decision) do
    active_answer = Decision.active_answer(decision)

    case Answers.request_version(state, decision.decision_id, active_answer.decision_version) do
      nil ->
        decision

      addressed ->
        %{
          addressed
          | answer: decision.answer,
            active_action_id: decision.active_action_id,
            revision_sequence: decision.revision_sequence,
            revisions: decision.revisions,
            revision_result: decision.revision_result,
            revision_outcomes: decision.revision_outcomes,
            revision_follow_ups: decision.revision_follow_ups,
            decision_status: decision.decision_status,
            delivery_status: decision.delivery_status,
            dispatch_attempts: decision.dispatch_attempts,
            acknowledgement: decision.acknowledgement,
            resolution: decision.resolution,
            acknowledgements: decision.acknowledgements,
            resolutions: decision.resolutions
        }
    end
  end

  @spec dispatchable?(term(), term()) :: term()
  def dispatchable?(%Decision{} = decision, _retry_failed?) when is_nil(decision.answer), do: false
  def dispatchable?(%Decision{decision_status: :resolved}, _retry_failed?), do: false
  def dispatchable?(%Decision{decision_status: :moot}, _retry_failed?), do: false
  def dispatchable?(%Decision{revision_result: :no_longer_applicable}, _retry_failed?), do: false
  def dispatchable?(%Decision{pending_for_session?: true}, _retry_failed?), do: false

  def dispatchable?(%Decision{} = decision, retry_failed?) do
    case List.last(Decision.active_dispatch_attempts(decision)) do
      nil -> true
      %{status: :failed} when retry_failed? -> true
      %{status: :failed, failure_reason_class: reason} -> transient_failure?(decision, reason)
      %{status: :unknown} -> true
      _other -> false
    end
  end

  @spec validate_explicit_retry(term(), term(), term()) :: term()
  def validate_explicit_retry(state, decision_id, action_id) do
    with {:ok, decision} <- Answers.fetch_decision(state, decision_id),
         %DecisionAnswer{action_id: ^action_id} <- Decision.active_answer(decision),
         :ok <- Answers.require_answerable(decision),
         true <- retryable_dispatch?(state, decision, action_id) do
      if Dispatch.dispatch_active?(state, action_id) do
        {:ok, :already_dispatching}
      else
        {:ok, decision}
      end
    else
      nil -> {:error, :answer_missing}
      %DecisionAnswer{} -> {:error, :action_mismatch}
      false -> {:error, :dispatch_not_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp retryable_dispatch?(state, decision, action_id) do
    match?(%{status: status} when status in [:failed, :unknown], List.last(Decision.active_dispatch_attempts(decision))) or
      lifecycle_append_failed?(state, action_id)
  end

  @spec lifecycle_append_failed?(term(), term()) :: term()
  def lifecycle_append_failed?(state, action_id) do
    MapSet.member?(Map.get(state, :lifecycle_append_failures, MapSet.new()), action_id)
  end

  # A new worker for the ticket is a new delivery target, so each answer that
  # failed to reach the previous (ended) worker is dispatched again with a
  # fresh retry ladder (#2713). `dispatch_active?/2` and the `:failed` attempt
  # check keep a second spawn, or a ladder retry racing this one, from sending
  # the same answer twice. The answers go out in the order the Commands were
  # decided: each dispatch is admitted here, in that order, and
  # `DecisionDispatchTasks` keeps admission order for one ticket.
  @spec schedule_pending_answer_delivery(term(), term()) :: term()
  def schedule_pending_answer_delivery(state, ticket_identifier) do
    state.current
    |> Map.values()
    |> Enum.filter(&answer_awaiting_worker?(&1, ticket_identifier))
    |> Enum.sort_by(&{&1.answer.accepted_at, &1.decision_id}, fn {left_at, left_id}, {right_at, right_id} ->
      case DateTime.compare(left_at, right_at) do
        :eq -> left_id <= right_id
        order -> order == :lt
      end
    end)
    |> Enum.reduce(state, fn decision, acc ->
      action_id = Decision.active_answer(decision).action_id

      if Dispatch.dispatch_active?(acc, action_id) or lifecycle_append_failed?(acc, action_id) do
        acc
      else
        Logger.info("Redelivering Decision answer to the new worker ticket=#{ticket_identifier} decision_id=#{decision.decision_id} action_id=#{action_id}")

        %{acc | retry_counts: Map.delete(acc.retry_counts, action_id)}
        |> Dispatch.maybe_start_dispatch(Dispatch.dispatch_fence(decision), true)
      end
    end)
  end

  # Only the active answer of a `:decided` Command qualifies, and only while
  # `dispatchable?/2` would send it: no attempt yet, or a failed newest attempt.
  # A queued, restored or consumed answer is not sent again. An attempt that
  # the provider confirmed (`delivered_at`) and that later failed is excluded
  # too, because the agent already saw that answer. A `:moot` Command (#2711)
  # is not `:decided`, and a replaced answer is not the active one, so neither
  # is ever redelivered.
  defp answer_awaiting_worker?(
         %Decision{decision_status: :decided, ticket: %{identifier: ticket_identifier}} = decision,
         ticket_identifier
       ) do
    dispatchable?(decision, true) and
      Enum.all?(Decision.active_dispatch_attempts(decision), &is_nil(&1.delivered_at))
  end

  defp answer_awaiting_worker?(_decision, _ticket_identifier), do: false
end

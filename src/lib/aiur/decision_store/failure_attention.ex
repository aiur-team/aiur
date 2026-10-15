defmodule Aiur.DecisionStore.FailureAttention do
  @moduledoc false

  require Logger

  alias Aiur.Commands.DeliveryTarget
  alias Aiur.Decision
  alias Aiur.Issue
  alias Aiur.Signal
  alias Aiur.Tracker

  # Delivery failures whose target is structurally unreachable cannot be made
  # actionable by re-raising them as needs-attention: an agent that no longer
  # exists cannot act, so the alert would assert the opposite of its own
  # reason. These are never raised as needs-attention and always clear the
  # delivery topic via its `.resolved` record, so a raised entry from an older
  # build (or an earlier attempt) is retired rather than left active (#2419).
  #
  # "Non-actionable" is an alert-surface verdict, not a liveness one: the same
  # class is transient in `@transient_failure_classes`, so a
  # temporarily-restarting agent is retried automatically rather than left for
  # the operator. The suppression only holds while that ladder still has
  # attempts left; once it is spent, `emit_retry_exhausted_attention/3` raises
  # regardless of class, because "nothing can act on this" stops being true
  # the moment the operator is the only thing left that can (#2558).
  @non_actionable_failure_classes ["target_agent_unavailable"]

  @spec project_delivery_attention(term(), term(), term(), term()) :: term()
  def project_delivery_attention(state, _prior, updated, :failed) do
    emit_failure_attention(updated)
    state
  end

  def project_delivery_attention(state, prior, updated, type)
      when type in [:dispatch_queued, :restored, :delivered, :acknowledged] do
    if prior.delivery_status == :failed or outcome_unknown_pending?(prior), do: emit_failure_resolution(updated)
    state
  end

  def project_delivery_attention(state, _prior, _updated, _type), do: state

  # A retry ladder spent on unknown outcomes raises an alert, and the late item
  # can still be adopted after that, so adoption clears it (#2717).
  @spec outcome_unknown_pending?(term()) :: term()
  def outcome_unknown_pending?(decision),
    do: match?(%{status: :unknown}, List.last(Decision.active_dispatch_attempts(decision)))

  @spec maybe_project_delivery_attention(term(), term(), term(), term(), term()) :: term()
  def maybe_project_delivery_attention(state, prior, updated, type, action_id) do
    if prior.active_action_id == action_id,
      do: project_delivery_attention(state, prior, updated, type),
      else: state
  end

  # The daemon-start failure reprojection is what #2419 calls out: every boot
  # used to re-fire a needs-attention alert for every failed delivery, which
  # produced a sub-second burst of stale entries for decisions whose tickets
  # closed long ago. Failures whose reason is structurally non-actionable
  # (`target_agent_unavailable`) are never raised; the boot pass resolves
  # (clears) the delivery topic once for each of them — retiring any alert an
  # older build already raised — and never consults the terminal resolver,
  # because they are non-actionable regardless of ticket state. The rest are
  # checked against the tracker's current ticket state so a decision on a
  # terminal ticket is *resolved* (its active alert cleared) rather than
  # re-raised. The tracker round-trip is batch and runs in a detached Task so
  # boot never blocks on GitHub; a resolver failure fails open (nothing treated
  # as terminal) so today's re-raise behavior survives a tracker outage.
  @spec schedule_failure_attention_reprojection(term()) :: term()
  def schedule_failure_attention_reprojection(state) do
    failed =
      state.current
      |> Map.values()
      |> Enum.filter(&(&1.delivery_status == :failed and &1.decision_status != :moot and not is_nil(Decision.active_answer(&1))))

    {non_actionable, checkable} = Enum.split_with(failed, &non_actionable_failure?/1)

    Enum.each(non_actionable, &emit_failure_resolution(&1, :non_actionable))

    case checkable do
      [] ->
        :ok

      _checkable ->
        store = self()
        resolver = state.terminal_ticket_resolver

        _ =
          Task.start(fn ->
            reproject_failure_attentions(store, resolver, checkable)
          end)

        :ok
    end
  end

  defp reproject_failure_attentions(store, resolver, failed) do
    terminal_ticket_ids = resolve_terminal_ticket_ids(resolver, failed)

    Enum.each(failed, fn decision ->
      if MapSet.member?(terminal_ticket_ids, decision.ticket.identifier) do
        emit_failure_resolution(decision, :terminal)
      else
        emit_failure_attention(decision)
      end
    end)

    send(store, {:failure_attention_reprojection_complete, length(failed)})
  rescue
    error ->
      Logger.warning("aiur_decision_store phase=failure_attention_reprojection_failed error=#{Exception.message(error)}")
  catch
    kind, reason ->
      Logger.warning("aiur_decision_store phase=failure_attention_reprojection_failed kind=#{kind} reason=#{inspect(reason)}")
  end

  defp resolve_terminal_ticket_ids(resolver, failed) do
    identifiers = failed |> Enum.map(& &1.ticket.identifier) |> Enum.uniq()

    try do
      case resolver.(identifiers) do
        {:ok, terminal} when is_struct(terminal, MapSet) -> terminal
        {:ok, terminal} when is_list(terminal) -> MapSet.new(terminal)
        {:error, reason} -> unresolved_terminal_ids(reason, identifiers)
      end
    rescue
      error -> unresolved_terminal_ids(error, identifiers)
    catch
      kind, reason -> unresolved_terminal_ids({kind, reason}, identifiers)
    end
  end

  defp unresolved_terminal_ids(reason, identifiers) do
    Logger.warning(
      "aiur_decision_store phase=failure_attention_terminal_resolution_failed " <>
        "tickets=#{inspect(identifiers)} reason=#{inspect(reason)}"
    )

    MapSet.new()
  end

  # The production resolver batch-reads the tracker's current issue states and
  # returns the ticket identifiers in terminal state. Fail-open on any read
  # error: an unreadable tracker must never be read as "everything terminal"
  # (which would clear live alerts), it is read as "nothing terminal" so the
  # conservative re-raise path stays in effect.
  @spec default_terminal_ticket_resolver(term()) :: term()
  def default_terminal_ticket_resolver(ticket_identifiers) do
    with {:ok, issues} <- Tracker.fetch_issue_states_by_ids(ticket_identifiers) do
      {:ok, terminal_identities(issues, DeliveryTarget.impl().terminal_state_set())}
    end
  end

  @doc false
  # Terminal ticket identities from one fetched issue-state batch. Mirrors the
  # established reader in `Aiur.DecisionRevisionDispatch`, which falls back to
  # `id` when `identifier` is blank: an adapter returning id-only issues must
  # still resolve as terminal, or this fix silently becomes a no-op on that
  # adapter with only a log line to say so.
  @spec terminal_identities([term()], MapSet.t(String.t())) :: MapSet.t(String.t())
  def terminal_identities(issues, terminal_states)
      when is_list(issues) and is_struct(terminal_states, MapSet) do
    issues
    |> Enum.filter(&DeliveryTarget.impl().terminal_issue_state?(&1.state, terminal_states))
    |> Enum.map(&issue_terminal_identity/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp issue_terminal_identity(%Issue{identifier: identifier}) when is_binary(identifier) and identifier != "",
    do: identifier

  defp issue_terminal_identity(%Issue{id: id}) when is_binary(id) and id != "", do: id
  defp issue_terminal_identity(_issue), do: nil

  defp non_actionable_failure?(decision) do
    case List.last(Decision.active_dispatch_attempts(decision)) do
      %{failure_reason_class: reason_class} when is_binary(reason_class) ->
        reason_class in @non_actionable_failure_classes

      _attempt ->
        false
    end
  end

  # Raising a delivery failure as needs-attention is only meaningful when the
  # target could still act. A structurally non-actionable failure
  # (`target_agent_unavailable`) must never raise: re-raising would demand
  # action nothing can take, and a `needs_attention: false` record on the bare
  # topic would only prepend to the feed, leaving any earlier raised entry
  # active. So the non-actionable branch clears the topic's `.resolved` record
  # instead — the only form `AlertFeed.resolve_attention_alerts/1` treats as a
  # clear — which both retires a prior raise (e.g. an earlier `send_failed`
  # attempt on the same topic) and keeps the decision off the needs-attention
  # feed (#2419, review).
  defp emit_failure_attention(%Decision{decision_status: :moot} = decision),
    do: emit_withdrawn_delivery_resolution(decision, decision.active_action_id, :moot)

  defp emit_failure_attention(decision) do
    if non_actionable_failure?(decision) do
      emit_failure_resolution(decision, :non_actionable)
    else
      emit_actionable_failure_attention(decision)
    end
  end

  defp emit_actionable_failure_attention(decision) do
    active_answer = Decision.active_answer(decision)

    reason_class =
      case List.last(Decision.active_dispatch_attempts(decision)) do
        %{failure_reason_class: reason_class} when is_binary(reason_class) -> reason_class
        _attempt -> "delivery_failed"
      end

    Signal.agent_alert(
      failure_attention_topic(decision),
      "Decision answer delivery failed for #{decision.decision_id} (#{reason_class}).",
      issue: decision.ticket.identifier,
      reason:
        "Decision #{decision.decision_id} action #{active_answer.action_id} " <>
          "remains actionable after #{reason_class}.",
      needs_attention: true,
      severity: "warning"
    )
  end

  defp emit_failure_resolution(decision), do: emit_failure_resolution(decision, :recovered)

  defp emit_failure_resolution(decision, :recovered) do
    active_answer = Decision.active_answer(decision)

    Signal.agent_alert(
      failure_attention_topic(decision) <> ".resolved",
      "Decision answer delivery recovered for #{decision.decision_id}.",
      issue: decision.ticket.identifier,
      reason: "Decision #{decision.decision_id} action #{active_answer.action_id} delivery recovered.",
      needs_attention: false,
      severity: "info"
    )
  end

  # A delivery that failed for a structurally non-actionable reason clears the
  # delivery topic exactly like a recovery or a terminal ticket does: the
  # `.resolved` record is the only form `AlertFeed` treats as a clear, so this
  # retires a raised entry from an older build or an earlier attempt on the
  # same topic while raising nothing new. Idempotent — re-emitting against a
  # topic with no active raise is a no-op via the alert emitter's edge-trigger.
  defp emit_failure_resolution(decision, :non_actionable) do
    active_answer = Decision.active_answer(decision)

    Signal.agent_alert(
      failure_attention_topic(decision) <> ".resolved",
      "Decision answer delivery is not actionable for #{decision.decision_id}: " <>
        "the target agent is absent.",
      issue: decision.ticket.identifier,
      reason:
        "Decision #{decision.decision_id} action #{active_answer.action_id} " <>
          "cannot be delivered while the target agent is absent; the delivery alert is " <>
          "cleared and the decision stays visible on the decision surface.",
      needs_attention: false,
      severity: "info"
    )
  end

  # Boot cleanup for a decision whose ticket has since gone terminal: the
  # delivery will never complete, so the stale needs-attention alert is cleared
  # instead of re-raised. Idempotent — re-running against an already-resolved
  # condition is a no-op via the alert emitter's edge-trigger.
  defp emit_failure_resolution(decision, :terminal) do
    active_answer = Decision.active_answer(decision)

    Signal.agent_alert(
      failure_attention_topic(decision) <> ".resolved",
      "Decision answer delivery is no longer actionable for #{decision.decision_id}: " <>
        "ticket #{decision.ticket.identifier} is terminal.",
      issue: decision.ticket.identifier,
      reason:
        "Decision #{decision.decision_id} action #{active_answer.action_id} " <>
          "targets a terminal ticket; the delivery alert is cleared.",
      needs_attention: false,
      severity: "info"
    )
  end

  # Backstop for #2711. The handoff mark makes a withdrawal after the gate
  # impossible, so a provider confirmation for a mooted Command or a replaced
  # action means an answer the operator withdrew reached an agent anyway. That
  # needs a human, so it is raised, never silently recorded.
  @spec maybe_alert_withdrawn_delivery(term(), term(), term()) :: term()
  def maybe_alert_withdrawn_delivery(%Decision{} = decision, :delivered, action_id) do
    why =
      cond do
        decision.decision_status == :moot -> "the Command was mooted"
        decision.active_action_id != action_id -> "a newer answer replaced it"
        true -> nil
      end

    if why do
      Signal.agent_alert(
        failure_attention_topic(decision, action_id) <> "-withdrawn",
        "A withdrawn Decision answer reached the agent for #{decision.decision_id}.",
        issue: decision.ticket.identifier,
        reason:
          "Decision #{decision.decision_id} action #{action_id} was delivered although #{why}. " <>
            "Tell the agent on ticket #{decision.ticket.identifier} to ignore it.",
        needs_attention: true,
        severity: "warning"
      )
    end

    :ok
  end

  def maybe_alert_withdrawn_delivery(_decision, _type, _action_id), do: :ok

  # A withdrawn answer (mooted, or replaced by a newer one) will never be
  # delivered, so any delivery alert raised for it is cleared rather than left
  # asking the operator to retry an answer that must not arrive (#2711).
  @spec emit_withdrawn_delivery_resolution(term(), term(), term()) :: term()
  def emit_withdrawn_delivery_resolution(decision, action_id, why) when is_binary(action_id) do
    detail =
      case why do
        :moot -> "the Command was mooted before its answer reached an agent"
        :superseded -> "a newer answer replaced it before it reached an agent"
      end

    Signal.agent_alert(
      failure_attention_topic(decision, action_id) <> ".resolved",
      "Decision answer delivery withdrawn for #{decision.decision_id}: #{detail}.",
      issue: decision.ticket.identifier,
      reason: "Decision #{decision.decision_id} action #{action_id} is withdrawn; #{detail}. It will not be delivered.",
      needs_attention: false,
      severity: "info"
    )
  end

  def emit_withdrawn_delivery_resolution(_decision, _action_id, _why), do: :ok

  @spec failure_attention_topic(term()) :: term()
  def failure_attention_topic(decision) do
    failure_attention_topic(decision, decision |> Decision.active_answer() |> Map.fetch!(:action_id))
  end

  @spec failure_attention_topic(term(), term()) :: term()
  def failure_attention_topic(decision, action_id) do
    action_slug = String.replace(action_id, "_", "-")
    "ticket.#{decision.ticket.identifier}.agent.attention.decision-delivery-#{action_slug}"
  end
end

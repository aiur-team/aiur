defmodule Aiur.DecisionHistory.EventProjection do
  @moduledoc false

  alias Aiur.{DecisionEvent, DecisionRevision}

  @spec record(DecisionEvent.t(), map(), map()) :: map()
  def record(%DecisionEvent{type: :answer_recorded, data: answer}, base, _revisions),
    do: Map.merge(base, %{answer: answer, event_kind: :answered})

  def record(%DecisionEvent{type: :decision_expired, data: data}, base, _revisions),
    do: Map.merge(base, %{actor: data.actor, rationale: data.reason_class, event_kind: :expired})

  def record(%DecisionEvent{type: :decision_mooted, data: data}, base, _revisions),
    do: Map.merge(base, %{actor: data.actor, rationale: data.reason_class, event_kind: :mooted})

  def record(%DecisionEvent{type: :decision_dismissed, data: data}, base, _revisions),
    do: Map.merge(base, %{actor: data.actor, event_kind: :dismissed})

  def record(%DecisionEvent{type: :revision_recorded, data: revision}, base, _revisions),
    do: Map.merge(base, %{revision: revision, revision_result: :recorded})

  def record(%DecisionEvent{type: :revision_dispatched, data: data}, base, revisions) do
    Map.merge(base, %{
      revision: Map.get(revisions, data.action_id),
      action_id: data.action_id,
      revision_result: :dispatched,
      dispatch_result: :queued
    })
  end

  def record(%DecisionEvent{type: :revision_no_longer_applicable, data: data}, base, revisions) do
    Map.merge(base, %{
      revision: Map.get(revisions, data.action_id),
      action_id: data.action_id,
      revision_result: :no_longer_applicable,
      dispatch_result: :not_applicable
    })
  end

  def record(%DecisionEvent{type: :follow_up_required, data: data}, base, revisions) do
    Map.merge(base, %{
      revision: Map.get(revisions, data.action_id),
      action_id: data.action_id,
      follow_up_required: true,
      follow_up_slug: data.slug,
      follow_up_required_at: base.recorded_at
    })
  end

  def record(%DecisionEvent{type: :follow_up_handled, data: data}, base, revisions) do
    Map.merge(base, %{
      revision: Map.get(revisions, data.action_id),
      action_id: data.action_id,
      actor: data.actor,
      follow_up_required: true,
      follow_up_handled: true,
      follow_up_slug: data.slug,
      follow_up_handled_at: base.recorded_at
    })
  end

  def record(%DecisionEvent{type: :executor_escalated, data: data}, base, _revisions) do
    Map.merge(base, %{actor: data.actor, escalated_to_operator: true, escalation_reason: data.detail})
  end

  def record(%DecisionEvent{type: :authority_reclassified, data: data}, base, _revisions),
    do: Map.merge(base, %{actor: data.actor, authority: data.authority, reclassification_rationale: data.detail})

  def record(%DecisionEvent{type: type, data: data}, base, actions)
      when type in [:dispatch_queued, :dispatch_outcome_unknown, :delivered, :restored, :consumed, :failed] do
    base
    |> Map.merge(action_context(Map.get(actions, data.action_id)))
    |> Map.merge(%{action_id: data.action_id, dispatch_result: type})
  end

  def record(%DecisionEvent{type: type, data: data}, base, actions)
      when type in [:acknowledged, :resolved] do
    base
    |> Map.merge(action_context(Map.get(actions, data.action_id)))
    |> Map.merge(%{action_id: data.action_id, actor: data.actor, acknowledgement_result: type})
  end

  def record(_event, base, _revisions), do: base

  defp action_context(%Aiur.DecisionAnswer{} = answer), do: %{answer: answer}
  defp action_context(%DecisionRevision{} = revision), do: %{revision: revision}
  defp action_context(_action), do: %{}
end

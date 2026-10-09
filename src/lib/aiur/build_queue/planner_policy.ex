defmodule Aiur.BuildQueue.PlannerPolicy do
  @moduledoc false
  alias Aiur.BuildQueue.Model.{Item, Observation}

  @spec decide(Item.t(), Observation.t() | nil, term(), map()) :: {atom(), term(), list()}
  def decide(item, observation, verdict, context) do
    labels = if observation, do: observation.labels, else: []
    prefix = Keyword.fetch!(context.opts, :label_prefix)
    todo = "#{prefix}:todo" in labels
    claim = if is_map(context.input.claims), do: Map.get(context.input.claims, item.issue_id, :unavailable), else: :unavailable
    facts = %{item: item, observation: observation, verdict: verdict, context: context, labels: labels, prefix: prefix, todo: todo, claim: claim}
    derive(facts)
  end

  defp derive(f) do
    cond do
      is_nil(f.observation) -> result(:unknown, :observation_unavailable)
      "#{f.prefix}:queued" not in f.labels -> result(:removed, nil, {:dequeue, f.item.issue_id})
      f.observation.open? == false -> closed(f.observation)
      f.observation.open? == :unknown -> result(:unknown, :observation_unavailable)
      claimed?(f) -> claimed(f)
      true -> managed(f)
    end
  end

  defp managed(f) do
    cond do
      f.item.override != nil -> result(:overridden, f.item.override)
      f.todo and not own_promotion?(f) -> result(:overridden, :manual_promotion, {:mark_override, f.item.issue_id})
      awaiting_promotion?(f) -> result(:unknown, :awaiting_promotion_observation)
      external_removal?(f) -> external_hold(f)
      held?(f) -> result(:held, f.item.hold || :queue_hold)
      true -> managed_labels(f)
    end
  end

  defp managed_labels(f) do
    cond do
      f.todo and own_promotion?(f) -> promoted(f)
      withdrawing?(f) and intent?(f, :withdraw) -> released(f)
      true -> ready_or_waiting(f)
    end
  end

  defp released(f) do
    {state, reason, _actions} = ready_or_waiting(f)
    result(state, reason, {:hold_release, f.item.issue_id})
  end

  defp closed(%Observation{state_reason: "completed"}), do: result(:completed, nil)
  defp closed(%Observation{state_reason: "not_planned"}), do: result(:cancelled, nil)
  defp closed(_observation), do: result(:unknown, :closed_reason)

  defp claimed?(f) do
    markers = ~w(queued paused parked)
    Enum.any?(f.labels, &(String.starts_with?(&1, "#{f.prefix}:") and &1 != "#{f.prefix}:todo" and String.replace_prefix(&1, "#{f.prefix}:", "") not in markers)) or f.claim == :claimed
  end

  defp claimed(f) do
    if withdrawing?(f), do: result(:claimed, nil, {:hold_release, f.item.issue_id}), else: result(:claimed, nil)
  end

  defp awaiting_promotion?(%{todo: false, item: %{promoted_at: %DateTime{} = promoted_at}, observation: observation}),
    do: observation.observed_at_ms <= DateTime.to_unix(promoted_at, :millisecond)

  defp awaiting_promotion?(_facts), do: false

  defp external_removal?(f), do: not f.todo and f.item.promoted_at != nil and not intent?(f, :withdraw)
  defp own_promotion?(f), do: f.item.promoted_at != nil or intent?(f, :promote)

  defp intent?(f, action) do
    Enum.any?(f.context.input.intents, fn intent ->
      intent.issue_id == f.item.issue_id and intent.action == action and intent.outcome in [nil, :ok] and
        intent.recorded_at_ms <= f.observation.observed_at_ms and MapSet.new(intent.target_labels) == MapSet.new(f.labels)
    end)
  end

  defp external_hold(%{item: %{hold: :external}}), do: result(:held, :external)
  defp external_hold(f), do: result(:held, :external, {:mark_external_hold, f.item.issue_id})

  defp held?(f), do: f.item.hold != nil or Map.fetch!(f.context.queues, f.item.queue_id).held
  defp withdrawing?(f), do: MapSet.member?(Keyword.get(f.context.opts, :withdrawal_holds, MapSet.new()), f.item.issue_id)

  defp promoted(%{claim: {:declined, :unauthorized}}), do: result(:promoted_unauthorized, :unauthorized)

  defp promoted(f) do
    cond do
      unavailable_unauthorized?(f) -> result(:promoted_unauthorized, :unauthorized)
      f.verdict == :ready and not held?(f) -> promoted_ready(f)
      not withdrawing?(f) -> result(:promoted, :withdrawal_pending, {:begin_withdraw, f.item.issue_id})
      f.claim == :unavailable -> result(:held, :claim_check_unavailable)
      f.claim == :unclaimed and fresh?(f) and not match?({:unknown, _}, f.verdict) -> result(:promoted, :withdrawal_pending, {:withdraw, f.item.issue_id})
      true -> result(:promoted, :withdrawal_pending)
    end
  end

  defp unavailable_unauthorized?(f), do: f.claim == :unavailable and Enum.any?(f.context.input.latches, &(&1.key == {:promoted_unauthorized, f.item.issue_id}))

  defp promoted_ready(f) do
    if withdrawing?(f), do: result(:promoted, nil, {:hold_release, f.item.issue_id}), else: result(:promoted, nil)
  end

  defp ready_or_waiting(%{verdict: {:unknown, reasons}}), do: result(:unknown, reasons)
  defp ready_or_waiting(%{verdict: {:failed, reasons}}), do: result(:failed_prerequisite, reasons)
  defp ready_or_waiting(%{verdict: :waiting}), do: result(:waiting, nil)

  defp ready_or_waiting(f) do
    cond do
      parked?(f) and not Keyword.get(f.context.opts, :promote_parked?, false) -> result(:held, :parked_marker)
      not fresh?(f) -> result(:unknown, :stale)
      true -> result(:ready, nil, {:promote, f.item.issue_id})
    end
  end

  defp parked?(f), do: Enum.any?(f.labels, &(&1 in ["#{f.prefix}:paused", "#{f.prefix}:parked", "needs-triage", "human:todo"] or String.starts_with?(&1, "epic:")))
  defp fresh?(f), do: f.observation.observed_at_ms <= f.context.input.now_ms and f.context.input.now_ms - f.observation.observed_at_ms <= Keyword.fetch!(f.context.opts, :observation_max_age_ms)
  defp result(state, reason), do: {state, reason, []}
  defp result(state, reason, action), do: {state, reason, [action]}
end

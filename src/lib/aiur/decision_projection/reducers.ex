defmodule Aiur.DecisionProjection.Reducers do
  @moduledoc false

  alias Aiur.{Decision, DecisionEvent, DecisionRevision}
  alias Aiur.DecisionProjection.{AuthorityReclassification, DeliveryReducers, TransitionValidation}

  @spec transition(term(), term()) :: {:ok, term()} | {:error, term()}
  def transition(%Decision{} = decision, %DecisionEvent{type: :answer_recorded, data: answer} = event) do
    with :ok <- TransitionValidation.require_current_version(decision, event.decision_version),
         :ok <- TransitionValidation.require_answer_identity(decision, answer),
         :ok <- TransitionValidation.require_option(decision, answer),
         :ok <- TransitionValidation.require_unanswered(decision) do
      {:ok,
       %{
         decision
         | answer: answer,
           active_action_id: answer.action_id,
           decision_status: :decided,
           delivery_status: :pending
       }}
    end
  end

  def transition(%Decision{decision_status: :open} = decision, %DecisionEvent{type: :decision_dismissed}) do
    {:ok, %{decision | decision_status: :dismissed, delivery_status: :not_dispatched}}
  end

  def transition(%Decision{decision_status: :deferred} = decision, %DecisionEvent{type: :decision_dismissed}) do
    {:ok, %{decision | decision_status: :dismissed, delivery_status: :not_dispatched}}
  end

  def transition(%Decision{decision_status: :dismissed} = decision, %DecisionEvent{type: :decision_dismissed}) do
    {:ok, decision}
  end

  def transition(%Decision{decision_status: :open} = decision, %DecisionEvent{type: :decision_deferred}) do
    {:ok, %{decision | decision_status: :deferred, delivery_status: :not_dispatched}}
  end

  def transition(%Decision{decision_status: :deferred} = decision, %DecisionEvent{type: :decision_deferred}) do
    {:ok, decision}
  end

  def transition(%Decision{decision_status: status} = decision, %DecisionEvent{type: :executor_escalated})
      when status in [:open, :deferred] do
    {:ok, decision}
  end

  def transition(decision, %DecisionEvent{type: :authority_reclassified} = event),
    do: AuthorityReclassification.transition(decision, event)

  def transition(%Decision{decision_status: :open} = decision, %DecisionEvent{type: :decision_expired}) do
    {:ok, %{decision | decision_status: :expired, delivery_status: :not_dispatched}}
  end

  def transition(%Decision{decision_status: :expired} = decision, %DecisionEvent{type: :decision_expired}) do
    {:ok, decision}
  end

  # A Command is moot when its ticket closed, its originating agent is gone, or
  # (for a decided Command, below) its answer was withdrawn before delivery.
  # The question itself is void, so neither `blocking` nor `authority` keeps it
  # answerable. The event records why and who. An open or deferred Command gets
  # no answer, so it stays durably distinguishable from a decided one.
  def transition(%Decision{decision_status: status} = decision, %DecisionEvent{type: :decision_mooted})
      when status in [:open, :deferred] do
    {:ok, %{decision | decision_status: :moot, delivery_status: :not_dispatched}}
  end

  def transition(%Decision{decision_status: :moot} = decision, %DecisionEvent{type: :decision_mooted}) do
    {:ok, decision}
  end

  # A decided answer that no agent has received yet can still be withdrawn
  # (#2711). The recorded answer stays in place for the audit trail, but the
  # `:moot` status makes it undeliverable. Once any action was handed off to a
  # worker or delivered, the answer is immutable and this event is refused.
  def transition(%Decision{decision_status: :decided} = decision, %DecisionEvent{type: :decision_mooted}) do
    cond do
      Decision.delivered?(decision) -> {:error, :answer_delivered}
      Decision.send_in_flight?(decision) -> {:error, :answer_in_flight}
      true -> {:ok, %{decision | decision_status: :moot, delivery_status: :not_dispatched}}
    end
  end

  def transition(%Decision{} = decision, %DecisionEvent{type: :revision_recorded, data: revision} = event) do
    with :ok <- TransitionValidation.require_current_version(decision, event.decision_version),
         {:ok, _answer} <- TransitionValidation.require_answer(decision),
         :ok <- TransitionValidation.require_revision_identity(decision, revision),
         :ok <- TransitionValidation.require_option(decision, revision.answer),
         :ok <- TransitionValidation.require_active_action(decision, revision.prior_action_id),
         :ok <- TransitionValidation.require_next_revision_sequence(decision, revision.sequence),
         :ok <- TransitionValidation.require_unknown_action(decision, revision.action_id) do
      outcome = TransitionValidation.revision_outcome(:recorded, nil, event)

      {:ok,
       %{
         decision
         | active_action_id: revision.action_id,
           revision_sequence: revision.sequence,
           revisions: decision.revisions ++ [revision],
           revision_result: :recorded,
           revision_outcomes: Map.put(decision.revision_outcomes, revision.action_id, outcome),
           decision_status: :decided,
           delivery_status: :pending,
           acknowledgement: nil,
           resolution: nil
       }}
    end
  end

  # A mooted Command was withdrawn before any delivery, so an agent cannot
  # acknowledge or resolve it; accepting one would revive it (#2711).
  def transition(%Decision{decision_status: :moot}, %DecisionEvent{type: type})
      when type in [:acknowledged, :resolved],
      do: {:error, :decision_moot}

  def transition(%Decision{} = decision, %DecisionEvent{type: :acknowledged} = event) do
    with {:ok, _answer} <- TransitionValidation.active_answer_for_event(decision, event),
         :ok <- TransitionValidation.require_absent(decision.acknowledgement, :already_acknowledged) do
      acknowledgement = TransitionValidation.lifecycle_fact(event)

      {:ok,
       %{
         decision
         | decision_status: :acknowledged,
           acknowledgement: acknowledgement,
           acknowledgements: Map.put(decision.acknowledgements, event.data.action_id, acknowledgement)
       }}
    end
  end

  def transition(%Decision{} = decision, %DecisionEvent{type: :resolved} = event) do
    with {:ok, _answer} <- TransitionValidation.active_answer_for_event(decision, event),
         :ok <- TransitionValidation.require_present(decision.acknowledgement, :not_acknowledged),
         :ok <- TransitionValidation.require_absent(decision.resolution, :already_resolved) do
      resolution = TransitionValidation.lifecycle_fact(event)

      {:ok,
       %{
         decision
         | decision_status: :resolved,
           resolution: resolution,
           resolutions: Map.put(decision.resolutions, event.data.action_id, resolution)
       }}
    end
  end

  def transition(%Decision{} = decision, %DecisionEvent{type: :revision_no_longer_applicable} = event) do
    with {:ok, %DecisionRevision{}} <- TransitionValidation.active_revision_for_event(decision, event),
         :ok <- TransitionValidation.require_revision_pending(decision) do
      outcome = TransitionValidation.revision_outcome(:no_longer_applicable, event.data.reason_class, event)

      {:ok,
       %{
         decision
         | revision_result: :no_longer_applicable,
           revision_outcomes: Map.put(decision.revision_outcomes, event.data.action_id, outcome),
           delivery_status: :not_dispatched
       }}
    end
  end

  def transition(%Decision{} = decision, %DecisionEvent{type: :follow_up_required} = event) do
    with {:ok, %DecisionRevision{}} <- TransitionValidation.active_revision_for_event(decision, event),
         :ok <- TransitionValidation.require_no_longer_applicable(decision),
         :ok <- TransitionValidation.require_follow_up_absent(decision, event.data.action_id) do
      follow_up = %{
        action_id: event.data.action_id,
        slug: event.data.slug,
        question: event.data.question,
        required_at: event.occurred_at,
        required_event_id: event.event_id,
        handled_at: nil,
        handled_event_id: nil,
        handled_by: nil,
        handled_detail: nil
      }

      {:ok, %{decision | revision_follow_ups: Map.put(decision.revision_follow_ups, event.data.action_id, follow_up)}}
    end
  end

  def transition(%Decision{} = decision, %DecisionEvent{type: :follow_up_handled} = event) do
    with {:ok, follow_up} <- TransitionValidation.fetch_open_follow_up(decision, event.data.action_id),
         :ok <- TransitionValidation.require_follow_up_slug(follow_up, event.data.slug) do
      handled = %{
        follow_up
        | handled_at: event.occurred_at,
          handled_event_id: event.event_id,
          handled_by: event.data.actor,
          handled_detail: event.data.detail
      }

      {:ok, %{decision | revision_follow_ups: Map.put(decision.revision_follow_ups, event.data.action_id, handled)}}
    end
  end

  def transition(%Decision{} = decision, %DecisionEvent{type: type} = event)
      when type in [:dispatch_queued, :revision_dispatched, :handed_off, :delivered, :restored, :consumed, :failed, :dispatch_outcome_unknown],
      do: DeliveryReducers.transition(decision, event)

  def transition(_decision, _event), do: {:error, :unsupported_event}
end

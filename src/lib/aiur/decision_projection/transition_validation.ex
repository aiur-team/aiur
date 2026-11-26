defmodule Aiur.DecisionProjection.TransitionValidation do
  @moduledoc false

  alias Aiur.{Decision, DecisionAnswer, DecisionEvent, DecisionRevision}

  @spec require_current_version(term(), term()) :: :ok | {:error, term()}
  def require_current_version(%Decision{version: version}, version), do: :ok
  def require_current_version(_decision, _version), do: {:error, :version_mismatch}

  @spec require_answer_identity(term(), term()) :: :ok | {:error, term()}
  def require_answer_identity(decision, answer) do
    if answer.decision_id == decision.decision_id and answer.decision_version == decision.version do
      :ok
    else
      {:error, :answer_identity_mismatch}
    end
  end

  @spec require_option(term(), term()) :: :ok | {:error, term()}
  def require_option(_decision, %DecisionAnswer{selected_option_id: nil}), do: :ok

  def require_option(decision, %DecisionAnswer{selected_option_id: option_id}) do
    if Enum.any?(decision.options, &(&1.id == option_id)), do: :ok, else: {:error, :unknown_option}
  end

  @spec require_unanswered(term()) :: :ok | {:error, term()}
  def require_unanswered(%Decision{answer: nil}), do: :ok
  def require_unanswered(_decision), do: {:error, :already_answered}

  @spec require_answer(term()) :: {:ok, DecisionAnswer.t()} | {:error, term()}
  def require_answer(%Decision{answer: %DecisionAnswer{} = answer}), do: {:ok, answer}
  def require_answer(_decision), do: {:error, :answer_missing}

  @spec require_revision_identity(term(), term()) :: :ok | {:error, term()}
  def require_revision_identity(decision, revision) do
    if revision.decision_id == decision.decision_id and revision.decision_version == decision.version,
      do: :ok,
      else: {:error, :revision_identity_mismatch}
  end

  @spec require_active_action(term(), term()) :: :ok | {:error, term()}
  def require_active_action(%Decision{active_action_id: action_id}, action_id), do: :ok
  def require_active_action(_decision, _action_id), do: {:error, :action_mismatch}

  @spec require_next_revision_sequence(term(), term()) :: :ok | {:error, term()}
  def require_next_revision_sequence(decision, sequence) do
    if sequence == decision.revision_sequence + 1, do: :ok, else: {:error, :revision_sequence_mismatch}
  end

  @spec require_unknown_action(term(), term()) :: :ok | {:error, term()}
  def require_unknown_action(decision, action_id) do
    if Enum.any?(all_answers(decision), &(&1.action_id == action_id)),
      do: {:error, :duplicate_action},
      else: :ok
  end

  defp all_answers(decision) do
    List.wrap(decision.answer) ++ Enum.map(decision.revisions, & &1.answer)
  end

  @spec answer_for_event(term(), term()) :: {:ok, term()} | {:error, term()}
  def answer_for_event(%Decision{answer: nil}, _event), do: {:error, :answer_missing}

  def answer_for_event(decision, event) do
    case Enum.find(all_answers(decision), &(&1.action_id == event.data.action_id)) do
      nil -> {:error, :action_mismatch}
      answer -> require_answer_event(answer, event) |> then(&if(&1 == :ok, do: {:ok, answer}, else: &1))
    end
  end

  @spec active_answer_for_event(term(), term()) :: {:ok, term()} | {:error, term()}
  def active_answer_for_event(decision, event) do
    with {:ok, answer} <- answer_for_event(decision, event),
         :ok <- require_active_action(decision, answer.action_id) do
      {:ok, answer}
    end
  end

  @spec active_revision_for_event(term(), term()) :: {:ok, term()} | {:error, term()}
  def active_revision_for_event(decision, event) do
    case List.last(decision.revisions) do
      %DecisionRevision{action_id: action_id, decision_version: version} = revision
      when action_id == event.data.action_id and version == event.decision_version ->
        {:ok, revision}

      _other ->
        {:error, :revision_action_mismatch}
    end
  end

  @spec require_revision_dispatch_kind(term(), term()) :: :ok | {:error, term()}
  def require_revision_dispatch_kind(
        %Decision{answer: %DecisionAnswer{action_id: action_id}},
        %DecisionEvent{type: :dispatch_queued, data: %{action_id: action_id}}
      ),
      do: :ok

  def require_revision_dispatch_kind(decision, %DecisionEvent{type: :revision_dispatched} = event) do
    case revision_for_event(decision, event) do
      {:ok, _revision} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def require_revision_dispatch_kind(_decision, _event), do: {:error, :dispatch_event_kind_mismatch}

  defp revision_for_event(decision, event) do
    case Enum.find(decision.revisions, &(&1.action_id == event.data.action_id)) do
      %DecisionRevision{decision_version: version} = revision when version == event.decision_version -> {:ok, revision}
      _other -> {:error, :revision_action_mismatch}
    end
  end

  @spec require_revision_pending(term()) :: :ok | {:error, term()}
  def require_revision_pending(%Decision{revision_result: :recorded}), do: :ok
  def require_revision_pending(_decision), do: {:error, :revision_not_pending}

  @spec require_no_longer_applicable(term()) :: :ok | {:error, term()}
  def require_no_longer_applicable(%Decision{revision_result: :no_longer_applicable}), do: :ok
  def require_no_longer_applicable(_decision), do: {:error, :revision_still_applicable}

  @spec require_follow_up_absent(term(), term()) :: :ok | {:error, term()}
  def require_follow_up_absent(decision, action_id) do
    if Map.has_key?(decision.revision_follow_ups, action_id), do: {:error, :follow_up_already_required}, else: :ok
  end

  @spec fetch_open_follow_up(term(), term()) :: {:ok, term()} | {:error, term()}
  def fetch_open_follow_up(decision, action_id) do
    case Map.get(decision.revision_follow_ups, action_id) do
      nil -> {:error, :follow_up_not_required}
      %{handled_at: nil} = follow_up -> {:ok, follow_up}
      _handled -> {:error, :follow_up_already_handled}
    end
  end

  @spec require_follow_up_slug(term(), term()) :: :ok | {:error, term()}
  def require_follow_up_slug(%{slug: slug}, slug), do: :ok
  def require_follow_up_slug(_follow_up, _slug), do: {:error, :follow_up_slug_mismatch}

  @spec revision_outcome(term(), term(), term()) :: map()
  def revision_outcome(result, reason_class, event) do
    %{
      result: result,
      reason_class: reason_class,
      occurred_at: event.occurred_at,
      event_id: event.event_id,
      run_id: event.run_id
    }
  end

  defp require_answer_event(answer, event) do
    cond do
      event.data.action_id != answer.action_id -> {:error, :action_mismatch}
      event.decision_version != answer.decision_version -> {:error, :version_mismatch}
      true -> :ok
    end
  end

  @spec lifecycle_fact(term()) :: map()
  def lifecycle_fact(event) do
    %{
      action_id: event.data.action_id,
      actor: event.data.actor,
      source: event.data.source,
      detail: event.data.detail,
      occurred_at: event.occurred_at,
      event_id: event.event_id,
      run_id: event.run_id
    }
  end

  @spec require_absent(term(), term()) :: :ok | {:error, term()}
  def require_absent(nil, _reason), do: :ok
  def require_absent(_value, reason), do: {:error, reason}
  @spec require_present(term(), term()) :: :ok | {:error, term()}
  def require_present(nil, reason), do: {:error, reason}
  def require_present(_value, _reason), do: :ok
end

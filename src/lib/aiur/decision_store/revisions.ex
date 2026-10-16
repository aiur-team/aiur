defmodule Aiur.DecisionStore.Revisions do
  @moduledoc false

  alias Aiur.Decision
  alias Aiur.DecisionAnswer
  alias Aiur.DecisionRevision
  alias Aiur.DecisionStore.AgentLifecycle
  alias Aiur.DecisionStore.Answers
  alias Aiur.DecisionStore.AppendRecovery
  alias Aiur.DecisionStore.Dispatch
  alias Aiur.DecisionStore.FailureAttention
  alias Aiur.DecisionStore.Persistence
  alias Aiur.DecisionStore.Settlement
  alias Aiur.DecisionStore.Withdrawals
  alias Aiur.SecretRedactor

  @spec handle_revision(term(), term(), term(), term()) :: term()
  def handle_revision(decision_id, payload, opts, state) do
    with {:ok, decision} <- Answers.fetch_decision(state, decision_id),
         %DecisionAnswer{} <- Decision.active_answer(decision),
         {:ok, actor} <- Answers.fetch_actor(opts) do
      case find_revision_replay(decision, payload) do
        %DecisionRevision{} = accepted -> replay_revision(decision, accepted, payload, actor, opts, state)
        nil -> accept_revision_unless_moot(decision, payload, actor, opts, state)
      end
    else
      nil -> {:reply, {:error, :answer_missing}, state}
      {:error, reason} -> {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  # A mooted Command must never deliver again, so a new revision cannot revive
  # it: the revision transition would set it back to `:decided` (#2711).
  defp accept_revision_unless_moot(%Decision{decision_status: :moot}, _payload, _actor, _opts, state),
    do: {:reply, {:error, {:conflict, :moot}}, state}

  defp accept_revision_unless_moot(decision, payload, actor, opts, state),
    do: accept_revision(decision, payload, actor, opts, state)

  # Supersede is the Executor's way to replace a decided answer that no agent
  # has received (#2711). It reuses the revision record, so the replaced answer
  # stays in the audit trail and only the newest action is dispatched. The
  # correlation comes from the current record inside this serialized call. An
  # exact retry keeps the correlation it was first recorded with, so it
  # replays as a duplicate even after the answer is delivered.
  @spec handle_supersede(term(), term(), term(), term()) :: term()
  def handle_supersede(decision_id, payload, opts, state) do
    with {:ok, decision} <- Answers.fetch_decision(state, decision_id),
         {:ok, _actor} <- Answers.fetch_actor(opts) do
      case find_revision_replay(decision, payload) do
        %DecisionRevision{} = accepted ->
          correlated = supersede_payload(payload, accepted.prior_action_id, accepted.sequence - 1)
          handle_revision(decision_id, correlated, opts, state)

        nil ->
          supersede_current(decision, payload, opts, state)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  defp supersede_current(decision, payload, opts, state) do
    case require_supersedable(decision) do
      :ok ->
        prior_action_id = decision.active_action_id
        correlated = supersede_payload(payload, prior_action_id, decision.revision_sequence)
        reply = handle_revision(decision.decision_id, correlated, opts, state)
        clear_superseded_delivery_attention(reply, decision, prior_action_id)

      {:error, reason} ->
        {:reply, {:error, Withdrawals.withdrawal_refused(state, decision, reason)}, state}
    end
  end

  defp require_supersedable(%Decision{decision_status: :decided} = decision), do: Withdrawals.require_withdrawable(decision)

  defp require_supersedable(%Decision{decision_status: status}) when status in [:open, :deferred],
    do: {:error, {:not_decided, status}}

  defp require_supersedable(%Decision{decision_status: status}) when status in [:acknowledged, :resolved],
    do: {:error, {:conflict, :answer_delivered}}

  defp require_supersedable(%Decision{decision_status: status}), do: {:error, {:conflict, status}}

  defp supersede_payload(payload, expected_action_id, expected_revision_sequence) do
    payload
    |> Map.drop([:expected_action_id, :expected_revision_sequence])
    |> Map.put("expected_action_id", expected_action_id)
    |> Map.put("expected_revision_sequence", expected_revision_sequence)
  end

  # A replaced answer may have raised a delivery-failure alert (the Khala #12
  # and #13 answers did). Nothing will retry that action again, so the alert is
  # cleared once the replacement is durable.
  defp clear_superseded_delivery_attention({:reply, {:ok, %{status: :accepted}}, _state} = reply, decision, action_id) do
    FailureAttention.emit_withdrawn_delivery_resolution(decision, action_id, :superseded)
    reply
  end

  defp clear_superseded_delivery_attention(reply, _decision, _action_id), do: reply

  defp find_revision_replay(decision, payload) do
    case AgentLifecycle.payload_value(payload, :idempotency_key) do
      token when is_binary(token) ->
        action_id =
          token
          |> String.trim()
          |> SecretRedactor.redact()
          |> then(&DecisionAnswer.action_id(decision.decision_id, &1))

        Enum.find(decision.revisions, &(&1.action_id == action_id))

      _other ->
        nil
    end
  end

  defp accept_revision(decision, payload, actor, opts, state) do
    active_answer = Decision.active_answer(decision)

    case normalize_revision(
           decision,
           payload,
           actor,
           opts,
           state,
           active_answer.action_id,
           decision.revision_sequence
         ) do
      {:ok, revision} -> persist_revision(decision, revision, state)
      {:error, reason} -> {:reply, {:error, revision_error(reason, decision)}, state}
    end
  end

  defp replay_revision(decision, accepted, payload, actor, opts, state) do
    case normalize_revision(
           decision,
           payload,
           actor,
           opts,
           state,
           accepted.prior_action_id,
           accepted.sequence - 1,
           accepted.decision_version
         ) do
      {:ok, replayed}
      when replayed.action_id == accepted.action_id and
             replayed.content_hash == accepted.content_hash ->
        next_state = Dispatch.maybe_schedule_after_answer(state, decision, false)
        {:reply, {:ok, revision_result(:duplicate, decision, accepted)}, next_state}

      {:ok, replayed} when replayed.action_id == accepted.action_id ->
        {:reply, {:error, {:conflict, {:idempotency_conflict, accepted.action_id}}}, state}

      {:ok, _replayed} ->
        {:reply, {:error, {:conflict, {:revision_token_conflict, accepted.action_id}}}, state}

      {:error, reason} ->
        {:reply, {:error, revision_error(reason, decision)}, state}
    end
  end

  defp normalize_revision(
         decision,
         payload,
         actor,
         opts,
         state,
         current_action_id,
         current_revision_sequence,
         decision_version \\ nil
       ) do
    decision_version = decision_version || decision.version
    addressed = Answers.request_version(state, decision.decision_id, decision_version)
    options = if addressed, do: addressed.options, else: decision.options
    now = Keyword.get(opts, :now, DateTime.utc_now())
    request = addressed || decision
    normalization_opts = Keyword.put(opts, :now, now)

    answer_normalizer = fn answer_payload, _revision_opts ->
      Answers.normalize_answer(answer_payload, request, decision_version, options, actor, normalization_opts)
    end

    DecisionRevision.normalize(payload,
      decision_id: decision.decision_id,
      decision_version: decision_version,
      current_action_id: current_action_id,
      current_revision_sequence: current_revision_sequence,
      actor: actor,
      now: now,
      answer_normalizer: answer_normalizer
    )
  end

  defp revision_error({:revision_invalid, {:stale_action, correlation}}, decision),
    do: {:conflict, {:stale_action, Map.put(correlation, :revision_sequence, decision.revision_sequence)}}

  defp revision_error({:revision_invalid, {:stale_sequence, correlation}}, decision),
    do: {:conflict, {:stale_sequence, Map.put(correlation, :action_id, decision.active_action_id)}}

  defp revision_error({:revision_invalid, {:answer_invalid, {:stale_version, expected, current}}}, _decision),
    do: {:conflict, {:stale_version, expected, current}}

  defp revision_error(reason, _decision), do: reason

  defp persist_revision(decision, revision, state) do
    case Persistence.build_and_persist_event(:revision_recorded, decision, revision, revision.recorded_at, state) do
      {:ok, next_state, updated} ->
        next_state = Settlement.ensure_superseded_revision_follow_ups(next_state, updated)
        current = Map.fetch!(next_state.current, updated.decision_id)
        next_state = Dispatch.maybe_schedule_after_answer(next_state, current, false)
        {:reply, {:ok, revision_result(:accepted, current, revision)}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  defp revision_result(status, decision, revision) do
    %{
      status: status,
      decision: decision,
      action: revision,
      revision_result: Map.get(decision.revision_outcomes, revision.action_id, %{result: :recorded}).result,
      dispatch_status: Withdrawals.dispatch_status(decision)
    }
  end

  @spec do_handle_revision_follow_up(term(), term(), term(), term()) :: term()
  def do_handle_revision_follow_up(decision_id, action_id, opts, state) do
    with {:ok, decision} <- Answers.fetch_decision(state, decision_id),
         {:ok, follow_up} <- fetch_revision_follow_up(decision, action_id),
         {:ok, actor} <- Answers.fetch_actor(opts) do
      case follow_up.handled_at do
        nil -> persist_follow_up_handled(state, decision, follow_up, actor, Keyword.get(opts, :detail))
        %DateTime{} -> {:reply, {:ok, follow_up_result(:duplicate, decision, follow_up)}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  defp fetch_revision_follow_up(decision, action_id) do
    case Map.get(decision.revision_follow_ups, action_id) do
      nil -> {:error, :follow_up_not_required}
      follow_up -> {:ok, follow_up}
    end
  end

  defp persist_follow_up_handled(state, decision, follow_up, actor, detail) do
    data = %{action_id: follow_up.action_id, slug: follow_up.slug, actor: actor, detail: detail}

    case Persistence.build_and_persist_event(:follow_up_handled, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, updated} ->
        next_state = Dispatch.maybe_schedule_revision_follow_up_resolution(next_state, updated, follow_up.action_id)
        handled = Map.fetch!(updated.revision_follow_ups, follow_up.action_id)
        {:reply, {:ok, follow_up_result(:accepted, updated, handled)}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, AppendRecovery.retry_follow_up_append(state, decision, :follow_up_handled, data, reason)}
    end
  end

  defp follow_up_result(status, decision, follow_up) do
    %{
      status: status,
      decision_id: decision.decision_id,
      action_id: follow_up.action_id,
      slug: follow_up.slug,
      handled_at: follow_up.handled_at
    }
  end
end

defmodule Aiur.DecisionStore.Withdrawals do
  @moduledoc false

  alias Aiur.Decision
  alias Aiur.DecisionAnswer
  alias Aiur.DecisionAuthority
  alias Aiur.DecisionStore.AgentLifecycle
  alias Aiur.DecisionStore.Answers
  alias Aiur.DecisionStore.Audit
  alias Aiur.DecisionStore.FailureAttention
  alias Aiur.DecisionStore.Persistence
  alias Aiur.Signal

  @spec handle_dismiss(term(), term(), term()) :: term()
  def handle_dismiss(decision_id, opts, state) do
    with {:ok, decision} <- Answers.fetch_decision(state, decision_id),
         {:ok, actor} <- Answers.fetch_actor(opts) do
      cond do
        decision.decision_status == :dismissed ->
          {:reply, {:ok, %{status: :duplicate, decision: decision}}, state}

        decision.decision_status not in [:open, :deferred] and not expired_unanswered_blocker?(decision) ->
          {:reply, {:error, {:conflict, decision.decision_status}}, state}

        unresolvable_block?(decision) ->
          {:reply, {:error, {:conflict, :blocking_requires_answer}}, state}

        true ->
          persist_dismissal(decision, actor, state)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  # Dismissal records a status and stops: it delivers nothing to a waiting
  # agent. Live blocking Commands remain protected because dismissal would hide
  # a real gate. An expired blocker no longer holds dispatch, so an operator may
  # retire that stale record without leaving an invisible block.
  @spec unresolvable_block?(term()) :: term()
  def unresolvable_block?(%Decision{decision_status: :expired, blocking: true, answer: nil}), do: false
  def unresolvable_block?(%Decision{blocking: true, legacy_attention: nil}), do: true
  def unresolvable_block?(_decision), do: false

  # Mirrors `RetainedIndex.readable?/1`: a corrupt store still serves its
  # validated-prefix projection for reads, while an unavailable
  # store cannot be trusted. `blocked_ticket_ids/1` relies on this so a
  # genuinely-unavailable store fails closed instead of reading an empty
  # `current` as "no blocking Commands".
  @spec readable?(term()) :: term()
  def readable?({:projection_stale, _since}), do: true
  def readable?(:writable), do: true
  def readable?({:corrupt, _line, _reason}), do: true
  def readable?(_health), do: false

  # An open (`:open` or `:deferred`) blocking Command gates its ticket's
  # dispatch. Internal delivery/persistence alerts are operational notices
  # about an existing Command, not operator-facing blocks, so they are excluded
  # exactly as in `RetainedIndex.operator_command?/1`.
  #
  # An expired blocker means its original worker is gone. It remains visible,
  # answerable and eligible for re-raise, but must not strand a later dispatch.
  # An option-less legacy attention never gates dispatch either, even when it
  # was persisted `blocking: true`. `DecisionAttention.project_attention/3` now
  # files attentions unblocking, but records written before that fix are still
  # in operators' stores, and each one holds the whole dispatch gate for its
  # ticket while describing a block that was never real. Reading the gate off
  # the record's own shape retires those without a migration.
  @spec open_blocking_command?(term()) :: term()
  def open_blocking_command?(%Decision{legacy_attention: %{slug: slug}, options: []})
      when is_binary(slug),
      do: false

  def open_blocking_command?(%Decision{
        decision_status: status,
        blocking: true,
        legacy_attention: %{slug: slug}
      })
      when status in [:open, :deferred] do
    not String.starts_with?(slug, ["decision-delivery-", "decision-lifecycle-persistence-"])
  end

  def open_blocking_command?(%Decision{decision_status: status, blocking: true})
      when status in [:open, :deferred],
      do: true

  def open_blocking_command?(%Decision{}), do: false

  defp expired_unanswered_blocker?(%Decision{decision_status: :expired, blocking: true, answer: nil}), do: true
  defp expired_unanswered_blocker?(_decision), do: false

  @spec open_nonblocking_agent_question?(term()) :: term()
  def open_nonblocking_agent_question?(%Decision{
        decision_status: status,
        blocking: false,
        kind: kind,
        source: %{agent_id: agent_id}
      })
      when status in [:open, :deferred] and kind != "legacy_attention" and is_binary(agent_id) and agent_id != "",
      do: true

  def open_nonblocking_agent_question?(%Decision{}), do: false

  defp persist_dismissal(decision, actor, state) do
    case Persistence.build_and_persist_event(:decision_dismissed, decision, %{actor: actor}, DateTime.utc_now(), state) do
      {:ok, next_state, updated} ->
        {:reply, {:ok, %{status: :accepted, decision: updated}}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  @spec handle_defer(term(), term(), term()) :: term()
  def handle_defer(decision_id, opts, state) do
    with {:ok, decision} <- Answers.fetch_decision(state, decision_id),
         {:ok, actor} <- Answers.fetch_actor(opts) do
      case decision.decision_status do
        :open -> persist_deferral(decision, actor, state)
        :deferred -> {:reply, {:ok, %{status: :duplicate, decision: decision}}, state}
        status -> {:reply, {:error, {:conflict, status}}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  defp persist_deferral(decision, actor, state) do
    case Persistence.build_and_persist_event(:decision_deferred, decision, %{actor: actor}, DateTime.utc_now(), state) do
      {:ok, next_state, updated} ->
        {:reply, {:ok, %{status: :accepted, decision: updated}}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  @spec handle_expire(term(), term(), term(), term()) :: term()
  def handle_expire(decision_id, reason_class, opts, state) do
    case Answers.fetch_decision(state, decision_id) do
      {:ok, %{decision_status: :open} = decision} ->
        persist_expiration(decision, reason_class, opts, state)

      {:ok, %{decision_status: :expired} = decision} ->
        {:reply, {:ok, %{status: :duplicate, decision: decision}}, state}

      {:ok, decision} ->
        {:reply, {:error, {:conflict, decision.decision_status}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  defp persist_expiration(decision, reason_class, opts, state) do
    occurred_at = Keyword.get(opts, :now, DateTime.utc_now())
    data = %{reason_class: reason_class, actor: Audit.system_actor()}

    case Persistence.build_and_persist_event(:decision_expired, decision, data, occurred_at, state) do
      {:ok, next_state, updated} ->
        {:reply, {:ok, %{status: :accepted, decision: updated}}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  # A Command is moot when its ticket closed or its originating agent is gone.
  # Retiring it must stay attributed to whoever did it and must never look like
  # an answer, so the payload requires a bounded `reason_class` and the event
  # carries the caller's actor plus optional free-text `detail` — and `answer`
  # is deliberately left untouched. A moot Command may be blocking: the block
  # described a live question, and a void question has no waiting agent.
  @spec handle_moot(term(), term(), term(), term()) :: term()
  def handle_moot(decision_id, payload, opts, state) do
    with {:ok, decision} <- Answers.fetch_decision(state, decision_id),
         {:ok, actor} <- Answers.fetch_actor(opts),
         {:ok, reason_class} <- moot_reason_class(payload),
         {:ok, detail} <- moot_detail(payload),
         :ok <- require_moot_version(decision, payload) do
      case decision.decision_status do
        :open ->
          persist_mooting(decision, reason_class, detail, actor, state)

        :deferred ->
          persist_mooting(decision, reason_class, detail, actor, state)

        :expired when decision.blocking and is_nil(decision.answer) ->
          persist_mooting(decision, reason_class, detail, actor, state)

        :moot ->
          {:reply, {:ok, %{status: :duplicate, decision: decision}}, state}

        :decided ->
          moot_undelivered(decision, reason_class, detail, actor, state)

        status when status in [:acknowledged, :resolved] ->
          {:reply, {:error, {:conflict, :answer_delivered}}, state}

        status ->
          {:reply, {:error, {:conflict, status}}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  # The operator can change direction after a Command is decided but before its
  # answer reaches an agent. Mooting withdraws that answer: the answer stays in
  # the audit trail, the `:moot` status stops every later dispatch, and the
  # delivery gate refuses a copy that is already queued (#2711). A delivered
  # answer is immutable, so this is refused once any action was delivered.
  defp moot_undelivered(decision, reason_class, detail, actor, state) do
    with :ok <- require_withdrawable(decision),
         :ok <- require_executor_may_withdraw(decision, actor) do
      case persist_mooting(decision, reason_class, detail, actor, state) do
        {:reply, {:ok, %{status: :accepted}}, _next_state} = reply ->
          FailureAttention.emit_withdrawn_delivery_resolution(decision, decision.active_action_id, :moot)
          reply

        reply ->
          reply
      end
    else
      {:error, reason} -> {:reply, {:error, withdrawal_refused(state, decision, reason)}, state}
    end
  end

  @spec withdrawal_refused(term(), term(), term()) :: term()
  def withdrawal_refused(state, decision, {:conflict, :answer_in_flight} = reason) do
    maybe_alert_unknown_handoff(state, decision)
    reason
  end

  def withdrawal_refused(_state, _decision, reason), do: reason

  defp maybe_alert_unknown_handoff(state, decision) do
    now = DateTime.utc_now()

    stale =
      Enum.find(decision.dispatch_attempts, fn attempt ->
        Decision.attempt_in_flight?(attempt) and
          DateTime.diff(now, attempt.handed_off_at, :millisecond) >= state.handoff_unknown_after_ms
      end)

    if stale do
      Signal.agent_alert(
        FailureAttention.failure_attention_topic(decision, stale.action_id) <> "-unknown",
        "Decision answer send outcome is unknown for #{decision.decision_id}.",
        issue: decision.ticket.identifier,
        reason:
          "Decision #{decision.decision_id} action #{stale.action_id} was handed to a worker at " <>
            "#{DateTime.to_iso8601(stale.handed_off_at)} with no confirmation or failure since. " <>
            "It cannot be withdrawn; check whether the agent on ticket #{decision.ticket.identifier} received it.",
        needs_attention: true,
        severity: "warning"
      )
    end

    :ok
  end

  # Delivered answers are immutable. A handed-off answer with no outcome yet
  # is in flight: the worker may be sending it, so withdrawing it now would
  # race the send (#2711). After a recorded failure it can be withdrawn again.
  @spec require_withdrawable(term()) :: term()
  def require_withdrawable(decision) do
    cond do
      Decision.delivered?(decision) -> {:error, {:conflict, :answer_delivered}}
      Decision.send_in_flight?(decision) -> {:error, {:conflict, :answer_in_flight}}
      true -> :ok
    end
  end

  # Mooting a decided Command withdraws a recorded answer, which is more than an
  # Executor may do on its own. It may withdraw an answer that an Executor
  # recorded, or one it could have recorded itself (the same authority and
  # reversibility floor as `executor-answer`). Anything else is the operator's
  # call, so the Executor must escalate it (#2711).
  defp require_executor_may_withdraw(decision, %{kind: :executor}) do
    cond do
      match?(%DecisionAnswer{actor: %{kind: :executor}}, Decision.active_answer(decision)) ->
        :ok

      not DecisionAuthority.executor_authority_answerable?(decision) ->
        {:error, {:answer_invalid, {:executor_scope, {:authority, decision.authority}}}}

      not DecisionAuthority.executor_reversibility_answerable?(decision) ->
        {:error, {:answer_invalid, {:executor_scope, {:reversibility, decision.reversibility}}}}

      true ->
        :ok
    end
  end

  defp require_executor_may_withdraw(_decision, _actor), do: :ok

  # `--expected-version` guards a moot against a stale view of the Command.
  # Callers that send no version (the dashboard) are not checked.
  defp require_moot_version(decision, payload) do
    case AgentLifecycle.payload_value(payload, :expected_version) do
      nil -> :ok
      version when version == decision.version -> :ok
      version -> {:error, {:conflict, {:stale_version, version, decision.version}}}
    end
  end

  defp moot_reason_class(payload) do
    case AgentLifecycle.payload_value(payload, :reason_class) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:moot_invalid, {:reason_class, :missing}}}
          trimmed -> {:ok, trimmed}
        end

      _other ->
        {:error, {:moot_invalid, {:reason_class, :missing}}}
    end
  end

  defp moot_detail(payload) do
    case AgentLifecycle.payload_value(payload, :reason) || AgentLifecycle.payload_value(payload, :detail) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:ok, nil}
          trimmed -> {:ok, trimmed}
        end

      _other ->
        {:ok, nil}
    end
  end

  defp persist_mooting(decision, reason_class, detail, actor, state) do
    data = %{reason_class: reason_class, detail: detail, actor: actor}

    case Persistence.build_and_persist_event(:decision_mooted, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, updated} ->
        {:reply, {:ok, %{status: :accepted, decision: updated}}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  @spec dispatch_status(term()) :: term()
  def dispatch_status(%Decision{delivery_status: :pending}), do: :dispatch_pending
  def dispatch_status(%Decision{delivery_status: status}), do: status
end

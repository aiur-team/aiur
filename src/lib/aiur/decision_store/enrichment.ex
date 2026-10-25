defmodule Aiur.DecisionStore.Enrichment do
  @moduledoc false

  alias Aiur.Boot
  alias Aiur.DecisionEnrichment
  alias Aiur.DecisionEvent
  alias Aiur.DecisionProjection
  alias Aiur.DecisionStore.Answers
  alias Aiur.DecisionStore.Audit
  alias Aiur.DecisionStore.Dedup
  alias Aiur.DecisionStore.Index
  alias Aiur.DecisionStore.Persistence
  alias Aiur.DecisionStore.ProjectionRecovery
  alias Aiur.DecisionStore.Requests
  alias Aiur.DecisionStore.RetainedSnapshot
  alias Aiur.DecisionValidation

  @spec handle_enrichment(term(), term(), term(), term()) :: term()
  def handle_enrichment(decision_id, patch, opts, state) do
    with {:ok, current} <- Answers.fetch_decision(state, decision_id),
         {:ok, expected_version} <- enrichment_expected_version(opts),
         {:ok, base} <- enrichment_base(state, current, expected_version),
         normalization_opts <-
           opts
           |> Keyword.put(:expected_version, expected_version)
           |> Keyword.put_new(:now, DateTime.utc_now()),
         {:ok, enrichment} <- DecisionEnrichment.normalize(base, patch, normalization_opts) do
      apply_enrichment(state, current, enrichment, normalization_opts[:now])
    else
      {:error, reason} -> {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  defp enrichment_expected_version(opts) do
    case Keyword.get(opts, :expected_version) do
      version when is_integer(version) and version > 0 -> {:ok, version}
      _invalid -> {:error, {:enrichment_invalid, {:expected_version, :invalid}}}
    end
  end

  defp enrichment_base(state, current, expected_version) do
    cond do
      expected_version == current.version ->
        {:ok, current}

      base = Answers.request_version(state, current.decision_id, expected_version) ->
        {:ok, base}

      true ->
        {:error, {:conflict, {:stale_version, expected_version, current.version}}}
    end
  end

  defp apply_enrichment(state, current, enrichment, occurred_at) do
    case prior_enrichment(state, current.decision_id, enrichment.expected_version) do
      %DecisionEvent{} = prior ->
        evaluate_enrichment_replay(state, prior, enrichment)

      nil when enrichment.expected_version != current.version ->
        {:reply, {:error, {:conflict, {:stale_version, enrichment.expected_version, current.version}}}, state}

      nil when not enrichment.changed ->
        {:reply, {:ok, %{status: :duplicate, decision: current}}, state}

      nil ->
        persist_enrichment(state, current, enrichment, occurred_at)
    end
  end

  defp prior_enrichment(state, decision_id, expected_version) do
    state.audit_history
    |> Map.get(decision_id, [])
    |> Enum.find(fn
      %DecisionEvent{type: :enriched, data: %{expected_version: ^expected_version}} -> true
      _other -> false
    end)
  end

  defp evaluate_enrichment_replay(state, prior, enrichment) do
    if prior.data.actor == enrichment.actor and
         prior.data.decision.content_hash == enrichment.decision.content_hash do
      decision = enrichment_replay_decision(state, prior)
      {:reply, {:ok, %{status: :duplicate, decision: decision}}, state}
    else
      {:reply, {:error, {:conflict, {:idempotency_conflict, enrichment.expected_version}}}, state}
    end
  end

  defp enrichment_replay_decision(state, prior) do
    current = Map.fetch!(state.current, prior.decision_id)

    if current.version == prior.data.decision.version,
      do: current,
      else: prior.data.decision
  end

  defp persist_enrichment(state, current, enrichment, occurred_at) do
    data = %{
      decision: enrichment.decision,
      actor: enrichment.actor,
      expected_version: enrichment.expected_version
    }

    with {:ok, event_id} <- state.event_id_reserver.(),
         {:ok, event} <-
           DecisionEvent.new(:enriched, current.decision_id, enrichment.decision.version, data,
             event_id: event_id,
             run_id: Boot.run_id(),
             now: occurred_at
           ),
         {:ok, updated} <- Persistence.validate_transition(current, event),
         :ok <- Persistence.append_event(state, event) do
      next_state =
        %{
          state
          | current: Map.put(state.current, current.decision_id, updated),
            decision_index: Index.update_decision_index(state.decision_index, current, updated),
            retained_index: RetainedSnapshot.update_index(state.retained_index, current, updated),
            history: Map.update(state.history, current.decision_id, [event.data.decision], &[event.data.decision | &1]),
            audit_history: Map.update(state.audit_history, current.decision_id, [event], &(&1 ++ [event])),
            recent_audit: Audit.remember_recent_audit(state.recent_audit, event)
        }
        |> ProjectionRecovery.enqueue(updated, event)
        |> Persistence.repair_projection()

      {:reply, {:ok, %{status: :accepted, decision: updated}}, next_state}
    else
      {:error, :not_durable} -> {:reply, {:error, :event_id_not_durable}, state}
      {:error, reason} -> {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  @spec handle_attention_projection(term(), term(), term()) :: term()
  def handle_attention_projection(payload, opts, state) do
    case normalize_legacy_attention(payload, opts) do
      {:ok, decision} -> apply_attention_projection_for_source(decision, opts, state)
      {:error, reason} -> {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  defp apply_attention_projection_for_source(decision, opts, state) do
    case prior_source_event_result(decision, state) do
      {:duplicate, prior} ->
        {:reply, {:ok, %{status: :duplicate, decision: prior}}, state}

      {:conflict, event_id} ->
        {:reply, {:error, {:conflict, {:source_event_conflict, event_id}}}, state}

      :new ->
        apply_fresh_attention_projection(decision, opts, state)
    end
  end

  # A fresh attention may still collide with a recent same-agent, same-ticket
  # Command asking substantially the same question (#2099), so creation-time
  # dedup runs before a new row is accepted.
  defp apply_fresh_attention_projection(decision, opts, state) do
    case Map.get(state.current, decision.decision_id) do
      nil ->
        case Dedup.find_creation_duplicate(decision, state) do
          nil -> Requests.accept(%{decision | version: 1}, state)
          existing -> {:reply, {:ok, %{status: :duplicate, decision: existing}}, state}
        end

      existing ->
        apply_attention_projection(existing, decision, opts, state)
    end
  end

  defp apply_attention_projection(existing, decision, opts, state) do
    cond do
      existing.legacy_attention != decision.legacy_attention ->
        {:reply, {:error, {:legacy_attention, :provenance_mismatch}}, state}

      Keyword.get(opts, :legacy_import, false) ->
        {:reply, {:ok, %{status: :duplicate, decision: existing}}, state}

      existing.question == decision.question ->
        {:reply, {:ok, %{status: :duplicate, decision: existing}}, state}

      Index.legacy_question_version_limit_reached?(existing, state) ->
        limit = state.legacy_question_version_limit
        {:reply, {:error, {:legacy_attention, {:version_limit, limit}}}, state}

      true ->
        merge_attention_question(existing, decision, opts, state)
    end
  end

  defp merge_attention_question(existing, incoming, opts, state) do
    source_created_at = earliest_source_created_at(existing.source_created_at, incoming.source_created_at)

    payload =
      existing
      |> DecisionProjection.to_request_payload()
      |> Map.put("question", incoming.question)
      |> replace_source_created_at(source_created_at)

    normalize_opts =
      opts
      |> Keyword.put(:ticket, existing.ticket)
      |> Keyword.put(:source, incoming.source)
      |> Keyword.put(:now, incoming.created_at)
      |> Keyword.put(:legacy_attention, existing.legacy_attention)

    case DecisionValidation.normalize(payload, normalize_opts) do
      {:ok, merged} -> Requests.accept(%{merged | version: existing.version + 1}, state)
      {:error, reason} -> {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  @spec handle_attention_enrichment(term(), term(), term()) :: term()
  def handle_attention_enrichment(payload, opts, state) do
    with {:ok, decision} <- normalize_legacy_attention(payload, opts),
         {:ok, existing} <- fetch_legacy_attention(state, decision) do
      decision = preserve_source_created_at(existing, decision)
      apply_attention_enrichment(existing, decision, payload, state)
    else
      {:error, reason} -> {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  defp apply_attention_enrichment(existing, decision, payload, state) do
    case prior_source_event_result(decision, state) do
      {:duplicate, prior} ->
        {:reply, {:ok, %{status: :duplicate, decision: prior}}, state}

      {:conflict, event_id} ->
        {:reply, {:error, {:conflict, {:source_event_conflict, event_id}}}, state}

      :new ->
        apply_new_attention_enrichment(existing, decision, payload, state)
    end
  end

  defp apply_new_attention_enrichment(existing, decision, payload, state) do
    if explicit_version?(payload) or existing.content_hash != decision.content_hash do
      evaluate_attention_enrichment(existing, decision, payload, state)
    else
      {:reply, {:ok, %{status: :duplicate, decision: existing}}, state}
    end
  end

  defp evaluate_attention_enrichment(existing, decision, payload, state) do
    case fetch_attention_enrichment_version(payload, existing.version) do
      {:ok, requested_version} -> Requests.evaluate_and_apply(decision, requested_version, state)
      {:error, reason} -> {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  defp normalize_legacy_attention(payload, opts) do
    with {:ok, decision} <- DecisionValidation.normalize(payload, opts),
         %{} <- decision.legacy_attention do
      {:ok, decision}
    else
      nil -> {:error, {:legacy_attention, :missing_provenance}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_legacy_attention(state, decision) do
    case Map.get(state.current, decision.decision_id) do
      nil ->
        {:error, {:legacy_attention, :not_found}}

      %{legacy_attention: legacy_attention} = existing
      when legacy_attention == decision.legacy_attention ->
        {:ok, existing}

      _existing ->
        {:error, {:legacy_attention, :provenance_mismatch}}
    end
  end

  defp prior_source_event_result(decision, state) do
    case source_event_key(decision) do
      nil ->
        :new

      key ->
        state.history
        |> Map.get(decision.decision_id, [])
        |> Enum.find(&(source_event_key(&1) == key))
        |> case do
          nil -> :new
          %{content_hash: hash} = prior when hash == decision.content_hash -> {:duplicate, prior}
          _prior -> {:conflict, elem(key, 2)}
        end
    end
  end

  defp source_event_key(%{source: %{agent_id: agent_id, session_id: session_id, event_id: event_id}})
       when is_binary(event_id) and event_id != "" do
    {agent_id, session_id, event_id}
  end

  defp source_event_key(_decision), do: nil

  defp fetch_attention_enrichment_version(payload, current_version) do
    Requests.fetch_requested_version(payload, current_version + 1)
  end

  defp explicit_version?(payload) do
    not is_nil(Requests.raw_version(payload))
  end

  defp replace_source_created_at(payload, nil), do: Map.delete(payload, "created_at")

  defp replace_source_created_at(payload, source_created_at) do
    Map.put(payload, "created_at", DateTime.to_iso8601(source_created_at))
  end

  defp preserve_source_created_at(existing, incoming) do
    %{incoming | source_created_at: earliest_source_created_at(existing.source_created_at, incoming.source_created_at)}
  end

  defp earliest_source_created_at(nil, incoming), do: incoming
  defp earliest_source_created_at(existing, nil), do: existing

  defp earliest_source_created_at(existing, incoming) do
    if DateTime.compare(existing, incoming) == :gt, do: incoming, else: existing
  end
end

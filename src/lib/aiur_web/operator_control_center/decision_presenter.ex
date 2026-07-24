defmodule AiurWeb.OperatorControlCenter.DecisionPresenter do
  @moduledoc """
  Maps canonical OCC decision projections into sorted dashboard rows.

  Semantic and delivery state remain separate. The compact lifecycle is a
  display-only summary and never advances either canonical axis.
  """

  alias Aiur.{Decision, DecisionSanitizer}

  @urgency_rank %{low: 0, normal: 1, high: 2, critical: 3}

  @spec rows([Decision.t()]) :: [map()]
  def rows(decisions) when is_list(decisions) do
    decisions
    |> Enum.flat_map(&present/1)
    |> Enum.sort_by(&sort_key/1)
  end

  @doc "Maps one retained Decision into the safe dashboard row contract."
  @spec present(Decision.t()) :: [map()]
  def present(%Decision{} = decision) do
    [row(decision)]
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  def present(_decision), do: []

  @doc "Attaches the same redacted latency status used by overview and detail rows."
  @spec attach_latency([map()], map(), :ok | :unavailable) :: [map()]
  def attach_latency(decisions, snapshots, :ok) when is_list(decisions) and is_map(snapshots) do
    Enum.map(decisions, fn decision ->
      case Map.get(snapshots, decision.decision_id) do
        snapshot when is_map(snapshot) -> Map.put(decision, :latency, %{status: :available, snapshot: snapshot})
        _missing -> Map.put(decision, :latency, %{status: :missing, snapshot: nil})
      end
    end)
  end

  def attach_latency(decisions, _snapshots, health) when is_list(decisions) do
    Enum.map(decisions, &Map.put(&1, :latency, %{status: health, snapshot: nil}))
  end

  defp row(%Decision{} = decision) do
    active_answer = Decision.active_answer(decision)

    %{
      decision_id: decision.decision_id,
      version: decision.version,
      ticket: DecisionSanitizer.ticket(decision.ticket),
      source: DecisionSanitizer.source(decision.source),
      kind: decision.kind,
      authority: decision.authority,
      urgency: decision.urgency,
      blocking: decision.blocking,
      reversibility: decision.reversibility,
      question: decision.question,
      context: %{
        short: Map.get(decision.context, :short_summary),
        long_markdown: Map.get(decision.context, :long_context_markdown)
      },
      options: Enum.map(decision.options, &option_row/1),
      recommendation: decision.recommendation,
      consequence_of_delay: decision.consequence_of_delay,
      artifacts: DecisionSanitizer.artifacts(decision.artifacts),
      created_at: decision.created_at,
      source_created_at: decision.source_created_at,
      decision_status: decision.decision_status,
      delivery_status: decision.delivery_status,
      original_answer: answer_row(decision.answer),
      answer: answer_row(active_answer),
      active_action_id: decision.active_action_id,
      revision_sequence: decision.revision_sequence,
      revisions: Enum.map(decision.revisions, &revision_row(&1, decision.revision_outcomes)),
      revision_result: decision.revision_result,
      superseded?: decision.revision_sequence > 0,
      dispatch_attempts: Enum.map(decision.dispatch_attempts, &DecisionSanitizer.dispatch_attempt/1),
      acknowledgement: DecisionSanitizer.lifecycle_fact(decision.acknowledgement),
      resolution: DecisionSanitizer.lifecycle_fact(decision.resolution),
      revision_follow_ups: DecisionSanitizer.follow_ups(decision.revision_follow_ups),
      provenance: DecisionSanitizer.provenance(Map.get(decision, :provenance)),
      retryable: retryable?(decision),
      failure_reason: failure_reason(decision),
      lifecycle: lifecycle(decision)
    }
  end

  defp option_row(option) do
    %{
      id: Map.get(option, :id),
      label: Map.get(option, :label),
      description: Map.get(option, :description),
      benefits: Map.get(option, :benefits),
      drawbacks: Map.get(option, :drawbacks),
      risk: Map.get(option, :risk)
    }
  end

  defp answer_row(nil), do: nil

  defp answer_row(answer) do
    %{
      action_id: answer.action_id,
      decision_version: answer.decision_version,
      selected_option_id: answer.selected_option_id,
      custom_response: answer.custom_response,
      rationale: answer.rationale,
      actor: DecisionSanitizer.actor(answer.actor),
      supervisor_basis: answer.supervisor_basis,
      accepted_at: answer.accepted_at
    }
  end

  defp revision_row(revision, outcomes) do
    %{
      sequence: revision.sequence,
      action_id: revision.action_id,
      prior_action_id: revision.prior_action_id,
      answer: answer_row(revision.answer),
      reason: revision.reason,
      recorded_at: revision.recorded_at,
      result: get_in(outcomes, [revision.action_id, :result]) || :recorded
    }
  end

  defp lifecycle(%{delivery_status: :failed}), do: :delivery_failed
  defp lifecycle(%{decision_status: :dismissed}), do: :resolved
  defp lifecycle(%{decision_status: :resolved}), do: :resolved
  defp lifecycle(%{decision_status: :acknowledged}), do: :acknowledged
  defp lifecycle(%{delivery_status: status}) when status in [:delivered, :consumed], do: :delivered
  defp lifecycle(%{decision_status: :decided}), do: :dispatch_pending
  defp lifecycle(_decision), do: :recorded

  defp retryable?(%Decision{decision_status: status, delivery_status: :failed} = decision)
       when status != :resolved do
    not is_nil(Decision.active_answer(decision))
  end

  defp retryable?(_decision), do: false

  defp failure_reason(%Decision{} = decision) do
    decision
    |> Decision.active_dispatch_attempts()
    |> List.last()
    |> case do
      %{status: :failed, failure_reason_class: reason} -> reason
      _attempt -> nil
    end
  end

  defp sort_key(decision) do
    {
      not decision.blocking,
      -Map.get(@urgency_rank, decision.urgency, 0),
      datetime_sort_key(decision.created_at),
      decision.decision_id
    }
  end

  defp datetime_sort_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_sort_key(_datetime), do: 0
end

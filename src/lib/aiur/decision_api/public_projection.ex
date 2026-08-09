defmodule Aiur.DecisionApi.PublicProjection do
  @moduledoc false

  alias Aiur.{Decision, DecisionSanitizer}
  alias Aiur.DecisionApi.PublicLifecycleProjection

  @spec encode(Decision.t()) :: map()
  def encode(%Decision{} = decision) do
    active_answer = Decision.active_answer(decision)

    %{
      "decision_id" => decision.decision_id,
      "version" => decision.version,
      "ticket" => ticket(decision.ticket),
      "source" => source(decision.source),
      "kind" => decision.kind,
      "authority" => atom_name(decision.authority),
      "urgency" => atom_name(decision.urgency),
      "blocking" => decision.blocking,
      "reversibility" => atom_name(decision.reversibility),
      "question" => decision.question,
      "context" => context(decision.context),
      "options" => Enum.map(decision.options, &option/1),
      "recommendation" => recommendation(decision.recommendation),
      "consequence_of_delay" => decision.consequence_of_delay,
      "artifacts" => artifacts(decision.artifacts),
      "created_at" => timestamp(decision.created_at),
      "source_created_at" => timestamp(decision.source_created_at),
      "decision_status" => atom_name(decision.decision_status),
      "delivery_status" => atom_name(decision.delivery_status),
      "answer" => PublicLifecycleProjection.answer(decision.answer),
      "active_answer" => PublicLifecycleProjection.answer(active_answer),
      "active_action_id" => decision.active_action_id,
      "revision_sequence" => decision.revision_sequence,
      "revisions" => Enum.map(decision.revisions, &PublicLifecycleProjection.revision/1),
      "revision_result" => atom_name(decision.revision_result),
      "revision_outcomes" => PublicLifecycleProjection.revision_outcomes(decision.revision_outcomes),
      "revision_follow_ups" => PublicLifecycleProjection.revision_follow_ups(decision.revision_follow_ups),
      "dispatch_attempts" => Enum.map(decision.dispatch_attempts, &PublicLifecycleProjection.dispatch_attempt/1),
      "acknowledgement" => PublicLifecycleProjection.lifecycle_fact(decision.acknowledgement),
      "resolution" => PublicLifecycleProjection.lifecycle_fact(decision.resolution),
      "provenance" => provenance(decision.provenance)
    }
  end

  defp ticket(ticket) when is_map(ticket) do
    safe = DecisionSanitizer.ticket(ticket)

    %{
      "identifier" => safe.identifier,
      "title" => safe.title,
      "url" => safe.url
    }
  end

  defp source(source) when is_map(source), do: %{"agent_id" => DecisionSanitizer.source(source).agent_id}

  defp context(context) when is_map(context) do
    %{
      "short_summary" => value(context, :short_summary),
      "long_context_markdown" => value(context, :long_context_markdown)
    }
  end

  defp option(option) when is_map(option) do
    %{
      "id" => value(option, :id),
      "label" => value(option, :label),
      "description" => value(option, :description),
      "benefits" => value(option, :benefits),
      "drawbacks" => value(option, :drawbacks),
      "risk" => value(option, :risk)
    }
  end

  defp option(_option), do: %{}

  defp recommendation(recommendation) when is_map(recommendation) do
    %{"option_id" => value(recommendation, :option_id), "reason" => value(recommendation, :reason)}
  end

  defp recommendation(_recommendation), do: nil

  defp artifacts(artifacts) do
    artifacts
    |> DecisionSanitizer.artifacts()
    |> Enum.map(fn artifact -> %{"kind" => atom_name(artifact.kind), "value" => artifact.value} end)
  end

  defp provenance(provenance) when is_map(provenance) do
    provenance = DecisionSanitizer.provenance(provenance)

    %{
      "schema_version" => value(provenance, :schema_version),
      "agent_family" => value(provenance, :agent_family),
      "backend" => value(provenance, :backend),
      "requested_model" => value(provenance, :requested_model),
      "resolved_model" => value(provenance, :resolved_model),
      "attempt_id" => value(provenance, :attempt_id),
      "source" => value(provenance, :source),
      "captured_at" => provenance |> value(:captured_at) |> timestamp()
    }
  end

  defp provenance(_provenance), do: nil

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil
  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp(_datetime), do: nil
  defp atom_name(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_name(value) when is_binary(value), do: value
  defp atom_name(_value), do: nil
end

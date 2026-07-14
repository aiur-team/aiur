defmodule Aiur.DecisionApi.PublicProjection do
  @moduledoc false

  alias Aiur.{Decision, DecisionAnswer, DecisionRevision, SecretRedactor}

  @identity_max 256
  @canonical_agent_id ~r/\A(?:(?:agent|example-agent)-[A-Za-z0-9][A-Za-z0-9._-]*|codex|claude(?:-repl)?|legacy_attention)\z/
  @jwt ~r/\AeyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/

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
      "answer" => answer(decision.answer),
      "active_answer" => answer(active_answer),
      "active_action_id" => decision.active_action_id,
      "revision_sequence" => decision.revision_sequence,
      "revisions" => Enum.map(decision.revisions, &revision/1),
      "revision_result" => atom_name(decision.revision_result),
      "revision_outcomes" => revision_outcomes(decision.revision_outcomes),
      "revision_follow_ups" => revision_follow_ups(decision.revision_follow_ups),
      "dispatch_attempts" => Enum.map(decision.dispatch_attempts, &dispatch_attempt/1),
      "acknowledgement" => lifecycle_fact(decision.acknowledgement),
      "resolution" => lifecycle_fact(decision.resolution),
      "provenance" => provenance(decision.provenance)
    }
  end

  defp ticket(ticket) when is_map(ticket) do
    %{
      "identifier" => value(ticket, :identifier),
      "title" => value(ticket, :title),
      "url" => safe_ticket_url(value(ticket, :url))
    }
  end

  defp ticket(_ticket), do: %{"identifier" => nil, "title" => nil, "url" => nil}

  defp source(source) when is_map(source), do: %{"agent_id" => safe_agent_id(value(source, :agent_id))}
  defp source(_source), do: %{"agent_id" => nil}

  defp context(context) when is_map(context) do
    %{
      "short_summary" => value(context, :short_summary),
      "long_context_markdown" => value(context, :long_context_markdown)
    }
  end

  defp context(_context), do: %{"short_summary" => nil, "long_context_markdown" => nil}

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

  defp artifacts(artifacts) when is_list(artifacts) do
    Enum.flat_map(artifacts, fn
      artifact when is_map(artifact) -> artifact(artifact)
      _artifact -> []
    end)
  end

  defp artifacts(_artifacts), do: []

  defp artifact(artifact) do
    case {value(artifact, :kind), value(artifact, :value)} do
      {:path, path} when is_binary(path) -> [%{"kind" => "path", "value" => path}]
      {"path", path} when is_binary(path) -> [%{"kind" => "path", "value" => path}]
      {:url, url} when is_binary(url) -> safe_url_artifact(url)
      {"url", url} when is_binary(url) -> safe_url_artifact(url)
      _artifact -> []
    end
  end

  defp answer(nil), do: nil

  defp answer(%DecisionAnswer{} = answer) do
    %{
      "action_id" => answer.action_id,
      "decision_version" => answer.decision_version,
      "selected_option_id" => answer.selected_option_id,
      "custom_response" => answer.custom_response,
      "rationale" => answer.rationale,
      "actor" => actor(answer.actor),
      "supervisor_basis" => supervisor_basis(answer.supervisor_basis),
      "accepted_at" => timestamp(answer.accepted_at)
    }
  end

  defp answer(_answer), do: nil

  defp revision(%DecisionRevision{} = revision) do
    %{
      "sequence" => revision.sequence,
      "action_id" => revision.action_id,
      "prior_action_id" => revision.prior_action_id,
      "answer" => answer(revision.answer),
      "reason" => revision.reason,
      "recorded_at" => timestamp(revision.recorded_at)
    }
  end

  defp revision(_revision), do: %{}

  defp revision_outcomes(outcomes) when is_map(outcomes) do
    Map.new(outcomes, fn {action_id, outcome} ->
      {action_id,
       %{
         "result" => outcome |> value(:result) |> atom_name(),
         "reason_class" => value(outcome, :reason_class),
         "occurred_at" => outcome |> value(:occurred_at) |> timestamp()
       }}
    end)
  end

  defp revision_outcomes(_outcomes), do: %{}

  defp revision_follow_ups(follow_ups) when is_map(follow_ups) do
    Map.new(follow_ups, fn {action_id, follow_up} ->
      {action_id,
       %{
         "action_id" => value(follow_up, :action_id),
         "slug" => value(follow_up, :slug),
         "question" => value(follow_up, :question),
         "required_at" => follow_up |> value(:required_at) |> timestamp(),
         "handled_at" => follow_up |> value(:handled_at) |> timestamp(),
         "handled_by" => follow_up |> value(:handled_by) |> actor()
       }}
    end)
  end

  defp revision_follow_ups(_follow_ups), do: %{}

  defp dispatch_attempt(attempt) when is_map(attempt) do
    %{
      "action_id" => value(attempt, :action_id),
      "attempt_id" => value(attempt, :attempt_id),
      "queue_item_id" => value(attempt, :queue_item_id),
      "status" => attempt |> value(:status) |> atom_name(),
      "attempted_at" => attempt |> value(:attempted_at) |> timestamp(),
      "queued_at" => attempt |> value(:queued_at) |> timestamp(),
      "delivered_at" => attempt |> value(:delivered_at) |> timestamp(),
      "restored_at" => attempt |> value(:restored_at) |> timestamp(),
      "consumed_at" => attempt |> value(:consumed_at) |> timestamp(),
      "failed_at" => attempt |> value(:failed_at) |> timestamp(),
      "failure_reason_class" => value(attempt, :failure_reason_class)
    }
  end

  defp dispatch_attempt(_attempt), do: %{}

  defp lifecycle_fact(nil), do: nil

  defp lifecycle_fact(fact) when is_map(fact) do
    %{
      "action_id" => value(fact, :action_id),
      "actor" => fact |> value(:actor) |> actor(),
      "occurred_at" => fact |> value(:occurred_at) |> timestamp()
    }
  end

  defp lifecycle_fact(_fact), do: nil

  defp actor(actor) when is_map(actor), do: %{"kind" => actor |> value(:kind) |> atom_name()}
  defp actor(_actor), do: nil

  defp supervisor_basis(nil), do: nil

  defp supervisor_basis(basis) when is_map(basis) do
    policy_basis = value(basis, :policy_basis)

    %{
      "confidence" => value(basis, :confidence),
      "alternatives_considered" => value(basis, :alternatives_considered),
      "reversibility_belief" => basis |> value(:reversibility_belief) |> atom_name(),
      "policy_basis" => %{
        "authority" => policy_basis |> value(:authority) |> atom_name(),
        "kind" => value(policy_basis, :kind),
        "reversibility" => policy_basis |> value(:reversibility) |> atom_name(),
        "checks" => checks(policy_basis |> value(:checks)),
        "allow_non_reversible" => value(policy_basis, :allow_non_reversible)
      }
    }
  end

  defp supervisor_basis(_basis), do: nil

  defp checks(checks) when is_map(checks), do: Map.new(checks, fn {key, value} -> {to_string(key), value} end)
  defp checks(_checks), do: %{}

  defp provenance(provenance) when is_map(provenance) do
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

  defp safe_ticket_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: userinfo, query: query, fragment: fragment}
      when scheme in ["http", "https"] and is_binary(host) and userinfo in [nil, ""] and
             query in [nil, ""] and fragment in [nil, ""] ->
        value

      _uri ->
        nil
    end
  end

  defp safe_ticket_url(_value), do: nil

  defp safe_url_artifact(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: userinfo, query: query, fragment: fragment}
      when is_binary(host) and userinfo in [nil, ""] and query in [nil, ""] and fragment in [nil, ""] ->
        [%{"kind" => "url", "value" => value}]

      _uri ->
        []
    end
  end

  defp safe_agent_id(value) when is_binary(value) do
    if byte_size(value) <= @identity_max and
         SecretRedactor.redact(value) == value and
         not Regex.match?(@jwt, value) and
         Regex.match?(@canonical_agent_id, value) do
      value
    end
  end

  defp safe_agent_id(_value), do: nil

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil
  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp(_datetime), do: nil
  defp atom_name(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_name(value) when is_binary(value), do: value
  defp atom_name(_value), do: nil
end

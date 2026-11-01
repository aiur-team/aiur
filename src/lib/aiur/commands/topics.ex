defmodule Aiur.Commands.Topics do
  @moduledoc "Route Command lifecycle events to their requester's durable stream."

  require Logger

  alias Aiur.Commands.Requester
  alias Aiur.Decision
  alias Aiur.DecisionProjection
  alias Aiur.Events
  alias Aiur.ExecutorEvents

  @spec lifecycle(Decision.t(), String.t()) :: String.t()
  def lifecycle(decision, slug) do
    if Requester.executor?(decision),
      do: "executor.decision." <> slug,
      else: "ticket.#{decision.ticket.identifier}.agent.decision." <> slug
  end

  @spec publish(Decision.t(), String.t(), map(), pos_integer()) :: {:ok, pos_integer(), non_neg_integer()} | {:error, term()}
  def publish(decision, slug, payload, cursor_event_id) do
    topic = lifecycle(decision, slug)

    result =
      if Requester.executor?(decision) do
        if slug == "deferred" do
          # Keep the existing deferred payload and its journal deduplication contract.
          ExecutorEvents.publish_deferred(decision)
        else
          scrubbed = payload |> Map.put(:topic, topic) |> ExecutorEvents.scrub_untrusted_output() |> Map.delete(:topic)
          ExecutorEvents.publish(topic, scrubbed, source: :internal)
        end
      else
        Events.publish_persisted(topic, export_payload(decision, slug, payload), cursor_event_id,
          digest_source: :orchestrator,
          identity: Map.get(decision.ticket, :tracker_identity)
        )
      end

    case result do
      {:error, reason} -> Logger.warning("aiur_command phase=lifecycle_publisher_failed topic=#{topic} reason=#{inspect(reason)}")
      _published -> :ok
    end

    result
  end

  defp export_payload(decision, slug, payload) when slug in ["requested", "answered"] do
    request = DecisionProjection.to_json_safe(decision)

    payload
    |> Map.put("decision_id", decision.decision_id)
    |> Map.put("decision_version", payload_value(payload, :decision_version) || decision.version)
    |> Map.put("question", request["question"])
    |> Map.put("options", request["options"])
    |> maybe_put_answer(slug, payload)
  end

  defp export_payload(_decision, _slug, payload), do: payload

  defp maybe_put_answer(payload, "answered", event_payload) do
    case payload_value(event_payload, :data) do
      answer when is_map(answer) -> Map.put(payload, "answer", answer)
      _other -> payload
    end
  end

  defp maybe_put_answer(payload, _slug, _event_payload), do: payload

  defp payload_value(payload, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
end

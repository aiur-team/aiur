defmodule Aiur.Commands.Topics do
  @moduledoc "Route Command lifecycle events to their requester's durable stream."

  require Logger

  alias Aiur.Commands.Requester
  alias Aiur.Decision
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
        Events.publish_persisted(topic, payload, cursor_event_id, digest_source: :orchestrator)
      end

    case result do
      {:error, reason} -> Logger.warning("aiur_command phase=lifecycle_publisher_failed topic=#{topic} reason=#{inspect(reason)}")
      _published -> :ok
    end

    result
  end
end

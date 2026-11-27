defmodule Aiur.AgentTools.AgentEventErrors do
  @moduledoc false

  @spec payload(atom()) :: map()
  def payload(:invalid_event_arguments) do
    %{
      "error" => %{
        "message" => "`emit_event` expects an object with non-empty `name` and `message` strings and optional `payload` object."
      }
    }
  end

  def payload(:missing_event_name),
    do: %{"error" => %{"message" => "`emit_event.name` is required."}}

  def payload(:missing_event_message),
    do: %{"error" => %{"message" => "`emit_event.message` is required."}}

  def payload(:invalid_report_progress),
    do: %{"error" => %{"message" => "`report_progress` requires an integer percent from 0 to 100 and a non-empty one-line step no longer than 120 characters."}}

  def payload(:event_name_not_in_allowlist) do
    %{
      "error" => %{
        "message" =>
          "`emit_event.name` must match the agent vocabulary: report_progress, progress (bare; payload %{percent, label}), progress.<slug>, decision.<slug>, blocked, unblocked, attention.<slug>, attention.resolved, pause.request, custom.<slug>, or optimistic.integrated.",
        "examples" => [
          "progress",
          "progress.brainstorm-end",
          "decision.use-amqp-matcher",
          "blocked",
          "attention.scope-question",
          "custom.heartbeat"
        ]
      }
    }
  end

  def payload(:missing_topic_pattern),
    do: %{"error" => %{"message" => "`topic_pattern` is required."}}

  def payload(:invalid_topic_pattern),
    do: %{
      "error" => %{
        "message" => "`topic_pattern` must be non-empty, must not start or end with `.`, and must not contain `..`."
      }
    }

  def payload(:agent_subscription_scope_forbidden),
    do: %{
      "error" => %{
        "message" => "`aiur_subscribe.topic_pattern` must name one literal ticket, for example `ticket.42.#`; Executor, system, bare-wildcard, and wildcard-ticket patterns are unavailable to agents."
      }
    }

  def payload(:subscriber_unavailable),
    do: %{
      "error" => %{"message" => "`aiur_subscribe` is unavailable in the current runtime context."}
    }

  def payload(:unsubscriber_unavailable),
    do: %{
      "error" => %{
        "message" => "`aiur_unsubscribe` is unavailable in the current runtime context."
      }
    }
end

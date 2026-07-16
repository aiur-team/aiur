defmodule Aiur.Codex.DynamicTool.Errors do
  @moduledoc """
  Error payload catalog for dynamic tool failures.
  """

  alias Aiur.Codex.DynamicTool.Response

  @spec payload(term()) :: map()
  def payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  def payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  def payload(:invalid_review_thread_reply_arguments) do
    %{
      "error" => %{
        "message" => "`aiur_reply_review_thread` expects an object with non-empty `review_thread_id` and `body` strings."
      }
    }
  end

  def payload(:invalid_review_thread_resolution_arguments) do
    %{
      "error" => %{
        "message" => "`aiur_resolve_review_thread` expects an object with non-empty `review_thread_id` and `terminal_reply_body` strings."
      }
    }
  end

  def payload(:missing_review_thread_id),
    do: %{"error" => %{"message" => "`review_thread_id` is required."}}

  def payload(:missing_review_thread_terminal_reply_body),
    do: %{"error" => %{"message" => "`terminal_reply_body` is required."}}

  def payload(:missing_review_thread_body),
    do: %{"error" => %{"message" => "`aiur_reply_review_thread.body` is required."}}

  def payload({:review_thread_reply_not_verified, detail}) do
    %{
      "error" => %{
        "message" => "GitHub review thread reply was not verified.",
        "reason" => "review_thread_reply_not_verified",
        "detail" => Response.jsonable(detail)
      }
    }
  end

  def payload({:review_thread_resolution_not_permitted, detail}) do
    %{
      "error" => %{
        "message" => "GitHub review thread resolution was not permitted by the configured token.",
        "reason" => "review_thread_resolution_not_permitted",
        "detail" => Response.jsonable(detail)
      }
    }
  end

  def payload({:review_thread_not_resolved, detail}) do
    %{
      "error" => %{
        "message" => "GitHub review thread resolution did not report a resolved thread.",
        "reason" => "review_thread_not_resolved",
        "detail" => Response.jsonable(detail)
      }
    }
  end

  def payload({:review_thread_resolution_precondition_failed, detail}) do
    %{
      "error" => %{
        "message" => "GitHub review thread resolution precondition failed.",
        "reason" => "review_thread_resolution_precondition_failed",
        "detail" => Response.jsonable(detail)
      }
    }
  end

  def payload({:review_thread_resolution_not_authorized, detail}) do
    %{
      "error" => %{
        "message" => "GitHub review thread resolution is outside the CODEOWNERS trust boundary.",
        "reason" => "review_thread_resolution_not_authorized",
        "detail" => Response.jsonable(detail)
      }
    }
  end

  def payload({:github_graphql_errors, errors}) do
    %{
      "error" => %{
        "message" => "GitHub GraphQL request failed.",
        "reason" => "github_graphql_errors",
        "errors" => Response.jsonable(errors)
      }
    }
  end

  def payload(:invalid_alert_arguments) do
    %{
      "error" => %{
        "message" => "`emit_alert` expects an object with non-empty `name`, `message`, and `reason` strings plus a boolean `needs_attention`."
      }
    }
  end

  def payload(:missing_alert_name),
    do: %{"error" => %{"message" => "`emit_alert.name` is required."}}

  def payload(:missing_alert_message),
    do: %{"error" => %{"message" => "`emit_alert.message` is required."}}

  def payload(:missing_alert_reason),
    do: %{"error" => %{"message" => "`emit_alert.reason` is required."}}

  def payload(:missing_alert_needs_attention),
    do: %{"error" => %{"message" => "`emit_alert.needs_attention` must be true or false."}}

  def payload(:system_scope_reserved) do
    %{
      "error" => %{
        "message" => "`emit_alert` may not emit system-owned alerts under `task.*`, `agent.*`, or `chat.*`."
      }
    }
  end

  def payload(:alert_emitter_unavailable) do
    %{
      "error" => %{
        "message" => "`emit_alert` is unavailable in the current runtime context."
      }
    }
  end

  def payload(:event_publisher_unavailable) do
    %{
      "error" => %{
        "message" => "`emit_event` is unavailable in the current runtime context."
      }
    }
  end

  def payload({:decision_rejected, reason}) do
    %{
      "error" => %{
        "message" => "Decision request was rejected by the durable DecisionStore.",
        "reason" => inspect(reason)
      }
    }
  end

  def payload({:decision_lifecycle_rejected, reason}) do
    %{
      "error" => %{
        "message" => "Decision lifecycle event was rejected by the durable DecisionStore.",
        "reason" => inspect(reason)
      }
    }
  end

  def payload(:no_issue_identifier) do
    %{
      "error" => %{
        "message" => "Decision requests require a ticket identifier.",
        "reason" => "no_issue_identifier"
      }
    }
  end

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

  def payload(:event_name_not_in_allowlist) do
    %{
      "error" => %{
        "message" =>
          "`emit_event.name` must match the agent vocabulary: progress (bare; payload %{percent, label}), progress.<slug>, decision.<slug>, blocked, unblocked, attention.<slug>, attention.resolved, pause.request, or custom.<slug>.",
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

  def payload(:missing_issue_number),
    do: %{"error" => %{"message" => "`issue_number` is required."}}

  def payload(:invalid_issue_number),
    do: %{"error" => %{"message" => "`issue_number` must be a positive integer."}}

  def payload(:blocker_declarer_unavailable),
    do: %{
      "error" => %{
        "message" => "`aiur_declare_blocker` is unavailable in the current runtime context."
      }
    }

  def payload(:unblocker_unavailable),
    do: %{
      "error" => %{"message" => "`aiur_unblock` is unavailable in the current runtime context."}
    }

  def payload(:cycle_detected),
    do: %{
      "error" => %{
        "message" => "Declaring this blocker would create a dependency cycle. Resolve the chain before declaring."
      }
    }

  def payload(:blocker_not_found),
    do: %{
      "error" => %{"message" => "Blocker issue does not exist or is not visible to Aiur's token."}
    }

  def payload(:rate_limited),
    do: %{"error" => %{"message" => "Cycle pre-check exhausted API budget; retry later."}}

  def payload(:permission_denied),
    do: %{
      "error" => %{"message" => "Aiur's GitHub token lacks Issues:write scope for this repo."}
    }

  def payload(:coordination_indeterminate),
    do: %{
      "error" => %{
        "message" => "Coordination admission timed out and may already have been accepted. Do not retry until authoritative state is checked.",
        "reason" => "coordination_indeterminate"
      }
    }

  def payload(:coordination_overloaded),
    do:
      coordination_payload(
        "Coordination work is at capacity; wait for pending work to drain before retrying.",
        :coordination_overloaded
      )

  def payload(:coordination_unavailable),
    do:
      coordination_payload(
        "Coordination work is temporarily unavailable; retry after the coordinator recovers.",
        :coordination_unavailable
      )

  def payload(:coordination_timeout),
    do:
      coordination_payload(
        "Coordination work exceeded its configured operation timeout.",
        :coordination_timeout
      )

  def payload({:coordination_task_exit, detail}),
    do:
      coordination_payload(
        "Coordination work exited before returning a terminal result.",
        :coordination_task_exit,
        detail
      )

  def payload({:coordination_operation_exception, detail}),
    do:
      coordination_payload(
        "Coordination work raised before returning a terminal result.",
        :coordination_operation_exception,
        detail
      )

  def payload({:coordination_operation_failure, kind, detail}),
    do:
      coordination_payload(
        "Coordination work failed before returning a terminal result.",
        :coordination_operation_failure,
        %{kind: kind, detail: detail}
      )

  def payload(:custom_event_quota_exceeded) do
    %{
      "error" => %{
        "message" => "`emit_event` over the per-turn custom.* quota. Wait for the next turn or use a non-`custom.*` name."
      }
    }
  end

  def payload(:progress_cap_exceeded) do
    %{
      "error" => %{
        "message" => "`emit_event` over the per-turn `progress` cap (2 per turn). Wait for the next phase boundary to emit again."
      }
    }
  end

  def payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  def payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Aiur is missing Linear auth. Set `linear.api_key` in `.aiurconfig` or export `LINEAR_API_KEY`."
      }
    }
  end

  def payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  def payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  def payload(reason) do
    %{
      "error" => %{
        "message" => "Aiur tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp coordination_payload(message, reason, detail \\ nil) do
    error = %{"message" => message, "reason" => Atom.to_string(reason)}
    %{"error" => if(is_nil(detail), do: error, else: Map.put(error, "detail", Response.jsonable(detail)))}
  end
end

defmodule Aiur.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias Aiur.Linear.Client

  @emit_alert_tool "emit_alert"
  @emit_alert_description """
  Emit a custom Aiur alert with a scoped name and concise message.
  Reserved system scopes (`task.*`, `agent.*`, `chat.*`) are not allowed.
  """
  @emit_alert_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["name", "message"],
    "properties" => %{
      "name" => %{"type" => "string", "description" => "Scoped alert name such as `phase.work.start`."},
      "message" => %{"type" => "string", "description" => "Concise log-facing alert message."}
    }
  }
  @emit_event_tool "emit_event"
  @emit_event_description """
  Emit a cross-ticket Aiur event. Routes onto the `Aiur.Events.Exchange`
  topic exchange where other agents/the operator can subscribe by
  pattern. The `name` is a scoped vocabulary tag (`progress.<slug>`,
  `decision.<slug>`, `blocked`, `unblocked`, `attention.<slug>`,
  `attention.resolved`, `pause.request`, or `custom.<slug>`). The full
  published topic is `ticket.<your-issue>.agent.<name>`.

  Subscribers see your `message` and optional structured `payload`. Use
  `emit_event` for coordination signals an agent on another ticket might
  want to react to; use `emit_alert` for operator-facing audible alerts.
  """
  @emit_event_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["name", "message"],
    "properties" => %{
      "name" => %{
        "type" => "string",
        "description" =>
          "Vocabulary tag. One of: progress.<slug>, decision.<slug>, blocked, unblocked, attention.<slug>, attention.resolved, pause.request, custom.<slug>"
      },
      "message" => %{"type" => "string", "description" => "Short human-readable summary."},
      "payload" => %{
        "type" => ["object", "null"],
        "description" => "Optional structured data (e.g. {blocking_issue: 80, function: \"foo\"}).",
        "additionalProperties" => true
      }
    }
  }
  @aiur_subscribe_tool "aiur_subscribe"
  @aiur_subscribe_description """
  Subscribe the current issue to a topic pattern. Patterns use AMQP topic
  exchange syntax: `*` matches one segment, `#` matches zero or more.
  Example: `ticket.42.#` (everything about ticket 42),
  `*.*.branch.push` (any push on any ticket).

  Persistent: the subscription survives BEAM restarts. Use this for
  watch use cases; native blocker declarations (`aiur_declare_blocker`)
  auto-subscribe on their own and shouldn't be paired with manual
  `aiur_subscribe` calls.
  """
  @aiur_subscribe_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["topic_pattern"],
    "properties" => %{
      "topic_pattern" => %{
        "type" => "string",
        "description" => "AMQP-style topic pattern, e.g. `ticket.42.#`."
      }
    }
  }
  @aiur_unsubscribe_tool "aiur_unsubscribe"
  @aiur_unsubscribe_description """
  Remove a previously-added subscription by exact topic pattern. No-op if
  the pattern was not subscribed.
  """
  @aiur_unsubscribe_input_schema @aiur_subscribe_input_schema
  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Aiur's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @emit_alert_tool ->
        execute_emit_alert(arguments, opts)

      @emit_event_tool ->
        execute_emit_event(arguments, opts)

      @aiur_subscribe_tool ->
        execute_subscription(arguments, opts, :subscribe)

      @aiur_unsubscribe_tool ->
        execute_subscription(arguments, opts, :unsubscribe)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @emit_alert_tool,
        "description" => @emit_alert_description,
        "inputSchema" => @emit_alert_input_schema
      },
      %{
        "name" => @emit_event_tool,
        "description" => @emit_event_description,
        "inputSchema" => @emit_event_input_schema
      },
      %{
        "name" => @aiur_subscribe_tool,
        "description" => @aiur_subscribe_description,
        "inputSchema" => @aiur_subscribe_input_schema
      },
      %{
        "name" => @aiur_unsubscribe_tool,
        "description" => @aiur_unsubscribe_description,
        "inputSchema" => @aiur_unsubscribe_input_schema
      }
    ]
  end

  defp execute_subscription(arguments, opts, action) do
    handler =
      case action do
        :subscribe -> Keyword.get(opts, :subscriber)
        :unsubscribe -> Keyword.get(opts, :unsubscriber)
      end

    error_atom =
      case action do
        :subscribe -> :subscriber_unavailable
        :unsubscribe -> :unsubscriber_unavailable
      end

    with {:ok, pattern} <- normalize_topic_pattern(arguments),
         true <- is_function(handler, 1) || {:error, error_atom},
         :ok <- handler.(pattern) do
      dynamic_tool_response(true, Jason.encode!(%{"ok" => true, "topic_pattern" => pattern}, pretty: true))
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))

      false ->
        failure_response(tool_error_payload(error_atom))
    end
  end

  defp normalize_topic_pattern(arguments) when is_map(arguments) do
    case Map.get(arguments, "topic_pattern") || Map.get(arguments, :topic_pattern) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        cond do
          trimmed == "" ->
            {:error, :missing_topic_pattern}

          String.contains?(trimmed, "..") or
            String.starts_with?(trimmed, ".") or
              String.ends_with?(trimmed, ".") ->
            {:error, :invalid_topic_pattern}

          true ->
            {:ok, trimmed}
        end

      _ ->
        {:error, :missing_topic_pattern}
    end
  end

  defp normalize_topic_pattern(_), do: {:error, :invalid_topic_pattern}

  defp execute_emit_event(arguments, opts) do
    event_publisher = Keyword.get(opts, :event_publisher)

    with {:ok, name, message, payload} <- normalize_emit_event_arguments(arguments),
         :ok <- validate_emit_event_name(name),
         true <- is_function(event_publisher, 3) || {:error, :event_publisher_unavailable},
         {:ok, result} <- event_publisher.(name, message, payload) do
      dynamic_tool_response(
        true,
        Jason.encode!(
          %{"ok" => true, "name" => name, "message" => message, "result" => result},
          pretty: true
        )
      )
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))

      false ->
        failure_response(tool_error_payload(:event_publisher_unavailable))
    end
  end

  defp normalize_emit_event_arguments(arguments) when is_map(arguments) do
    with {:ok, name} <- normalize_emit_alert_string(arguments, "name", :missing_event_name),
         {:ok, message} <- normalize_emit_alert_string(arguments, "message", :missing_event_message) do
      payload =
        case Map.get(arguments, "payload") || Map.get(arguments, :payload) do
          %{} = map -> map
          _ -> %{}
        end

      {:ok, name, message, payload}
    end
  end

  defp normalize_emit_event_arguments(_arguments), do: {:error, :invalid_event_arguments}

  # Locked agent vocabulary per the Ticket A brainstorm. Any name not in
  # this list is rejected before publish — prevents agents from inventing
  # new event categories that other tickets/agents won't be subscribed to.
  @agent_event_allowlist [
    ~r/\Aprogress\.[a-z0-9][a-z0-9.-]{0,63}\z/,
    ~r/\Adecision\.[a-z0-9][a-z0-9.-]{0,63}\z/,
    ~r/\Aattention\.[a-z0-9][a-z0-9.-]{0,63}\z/,
    ~r/\Acustom\.[a-z0-9][a-z0-9.-]{0,63}\z/
  ]
  @agent_event_exact ["blocked", "unblocked", "attention.resolved", "pause.request"]

  defp validate_emit_event_name(name) do
    cond do
      name in @agent_event_exact -> :ok
      Enum.any?(@agent_event_allowlist, &Regex.match?(&1, name)) -> :ok
      true -> {:error, :event_name_not_in_allowlist}
    end
  end

  defp execute_emit_alert(arguments, opts) do
    alert_emitter = Keyword.get(opts, :alert_emitter)

    with {:ok, name, message} <- normalize_emit_alert_arguments(arguments),
         true <- is_function(alert_emitter, 2) || {:error, :alert_emitter_unavailable},
         :ok <- alert_emitter.(name, message) do
      dynamic_tool_response(
        true,
        Jason.encode!(%{"ok" => true, "name" => name, "message" => message}, pretty: true)
      )
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))

      false ->
        failure_response(tool_error_payload(:alert_emitter_unavailable))
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_emit_alert_arguments(arguments) when is_map(arguments) do
    with {:ok, name} <- normalize_emit_alert_string(arguments, "name", :missing_alert_name),
         {:ok, message} <- normalize_emit_alert_string(arguments, "message", :missing_alert_message) do
      {:ok, name, message}
    end
  end

  defp normalize_emit_alert_arguments(_arguments), do: {:error, :invalid_alert_arguments}

  defp normalize_emit_alert_string(arguments, key, error_reason) do
    value =
      case key do
        "name" -> Map.get(arguments, "name") || Map.get(arguments, :name)
        "message" -> Map.get(arguments, "message") || Map.get(arguments, :message)
      end

    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, error_reason}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, error_reason}
    end
  end

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_alert_arguments) do
    %{
      "error" => %{
        "message" => "`emit_alert` expects an object with non-empty `name` and `message` strings."
      }
    }
  end

  defp tool_error_payload(:missing_alert_name), do: %{"error" => %{"message" => "`emit_alert.name` is required."}}
  defp tool_error_payload(:missing_alert_message), do: %{"error" => %{"message" => "`emit_alert.message` is required."}}

  defp tool_error_payload(:system_scope_reserved) do
    %{
      "error" => %{
        "message" => "`emit_alert` may not emit system-owned alerts under `task.*`, `agent.*`, or `chat.*`."
      }
    }
  end

  defp tool_error_payload(:alert_emitter_unavailable) do
    %{
      "error" => %{
        "message" => "`emit_alert` is unavailable in the current runtime context."
      }
    }
  end

  defp tool_error_payload(:event_publisher_unavailable) do
    %{
      "error" => %{
        "message" => "`emit_event` is unavailable in the current runtime context."
      }
    }
  end

  defp tool_error_payload(:invalid_event_arguments) do
    %{
      "error" => %{
        "message" => "`emit_event` expects an object with non-empty `name` and `message` strings and optional `payload` object."
      }
    }
  end

  defp tool_error_payload(:missing_event_name),
    do: %{"error" => %{"message" => "`emit_event.name` is required."}}

  defp tool_error_payload(:missing_event_message),
    do: %{"error" => %{"message" => "`emit_event.message` is required."}}

  defp tool_error_payload(:event_name_not_in_allowlist) do
    %{
      "error" => %{
        "message" =>
          "`emit_event.name` must match the agent vocabulary: progress.<slug>, decision.<slug>, blocked, unblocked, attention.<slug>, attention.resolved, pause.request, or custom.<slug>.",
        "examples" => [
          "progress.brainstorm-end",
          "decision.use-amqp-matcher",
          "blocked",
          "attention.scope-question",
          "custom.heartbeat"
        ]
      }
    }
  end

  defp tool_error_payload(:missing_topic_pattern),
    do: %{"error" => %{"message" => "`topic_pattern` is required."}}

  defp tool_error_payload(:invalid_topic_pattern),
    do: %{
      "error" => %{
        "message" =>
          "`topic_pattern` must be non-empty, must not start or end with `.`, and must not contain `..`."
      }
    }

  defp tool_error_payload(:subscriber_unavailable),
    do: %{"error" => %{"message" => "`aiur_subscribe` is unavailable in the current runtime context."}}

  defp tool_error_payload(:unsubscriber_unavailable),
    do: %{
      "error" => %{
        "message" => "`aiur_unsubscribe` is unavailable in the current runtime context."
      }
    }

  defp tool_error_payload(:custom_event_quota_exceeded) do
    %{
      "error" => %{
        "message" =>
          "`emit_event` over the per-turn custom.* quota. Wait for the next turn or use a non-`custom.*` name."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Aiur is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end

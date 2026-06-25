defmodule Aiur.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias Aiur.Linear.Client

  @emit_alert_tool "emit_alert"
  @emit_alert_description """
  Emit a custom Aiur alert with a scoped name, concise message, and
  structured operator context.
  Reserved system scopes (`task.*`, `agent.*`, `chat.*`) are not allowed.
  """
  @emit_alert_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["name", "message", "reason", "needs_attention"],
    "properties" => %{
      "name" => %{"type" => "string", "description" => "Scoped alert name such as `phase.work.start`."},
      "message" => %{"type" => "string", "description" => "Concise log-facing alert message."},
      "reason" => %{
        "type" => "string",
        "description" => "Human-readable reason or context the operator should relay."
      },
      "needs_attention" => %{
        "type" => "boolean",
        "description" => "True only when the operator should look or act now."
      },
      "severity" => %{
        "type" => "string",
        "description" => "Optional severity label such as info, warning, or critical."
      }
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
          "Vocabulary tag. One of: progress (bare; payload %{percent, label}), progress.<slug>, decision.<slug>, blocked, unblocked, attention.<slug>, attention.resolved, pause.request, custom.<slug>"
      },
      "message" => %{"type" => "string", "description" => "Short human-readable summary."},
      "payload" => %{
        "type" => ["object", "null"],
        "description" => "Optional structured data (e.g. {blocking_issue: 80, function: \"foo\"}).",
        "additionalProperties" => true
      }
    }
  }
  @aiur_declare_blocker_tool "aiur_declare_blocker"
  @aiur_declare_blocker_description """
  Declare that another GitHub issue (by number) blocks the issue you
  are working on. Uses GitHub's native Issue Dependencies REST API.
  Cycle-checked client-side before submission. Returns success if the
  blocker is already declared (idempotent).
  """
  @aiur_declare_blocker_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_number"],
    "properties" => %{
      "issue_number" => %{
        "type" => ["integer", "string"],
        "description" => "Issue number of the blocker (numeric, not the internal id)."
      }
    }
  }
  @aiur_unblock_tool "aiur_unblock"
  @aiur_unblock_description """
  Remove a previously-declared blocker from your current issue.
  """
  @aiur_unblock_input_schema @aiur_declare_blocker_input_schema
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

      @aiur_declare_blocker_tool ->
        execute_dependency_action(arguments, opts, :declare)

      @aiur_unblock_tool ->
        execute_dependency_action(arguments, opts, :unblock)

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
      },
      %{
        "name" => @aiur_declare_blocker_tool,
        "description" => @aiur_declare_blocker_description,
        "inputSchema" => @aiur_declare_blocker_input_schema
      },
      %{
        "name" => @aiur_unblock_tool,
        "description" => @aiur_unblock_description,
        "inputSchema" => @aiur_unblock_input_schema
      }
    ]
  end

  defp execute_dependency_action(arguments, opts, action) do
    handler =
      case action do
        :declare -> Keyword.get(opts, :blocker_declarer)
        :unblock -> Keyword.get(opts, :unblocker)
      end

    error_atom =
      case action do
        :declare -> :blocker_declarer_unavailable
        :unblock -> :unblocker_unavailable
      end

    with {:ok, issue_number} <- normalize_issue_number(arguments),
         true <- is_function(handler, 1) || {:error, error_atom},
         {:ok, result} <- handler.(issue_number) do
      dynamic_tool_response(
        true,
        Jason.encode!(%{"ok" => true, "issue_number" => issue_number, "result" => result_jsonable(result)}, pretty: true)
      )
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))

      false ->
        failure_response(tool_error_payload(error_atom))
    end
  end

  defp normalize_issue_number(arguments) when is_map(arguments) do
    case Map.get(arguments, "issue_number") || Map.get(arguments, :issue_number) do
      n when is_integer(n) and n > 0 ->
        {:ok, n}

      n when is_binary(n) ->
        case Integer.parse(String.trim(n)) do
          {parsed, ""} when parsed > 0 -> {:ok, parsed}
          _ -> {:error, :invalid_issue_number}
        end

      _ ->
        {:error, :missing_issue_number}
    end
  end

  defp normalize_issue_number(_), do: {:error, :invalid_issue_number}

  defp result_jsonable(value) when is_atom(value), do: Atom.to_string(value)
  defp result_jsonable(value) when is_map(value) or is_list(value) or is_binary(value), do: value
  defp result_jsonable(value), do: inspect(value)

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
         :ok <- enforce_per_turn_quota(name),
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
  @agent_event_exact ["progress", "blocked", "unblocked", "attention.resolved", "pause.request"]

  # Bare-`progress` emits carry %{percent, label} samples for the agent-list
  # progress bar. Agents target one emit per phase boundary; the cap exists
  # to keep mid-phase corrections rare and the lifetime budget around 8-15
  # emits per ticket. 3rd progress emit in a single codex turn is rejected
  # so the agent reads the error and learns the constraint.
  @progress_emits_per_turn_max 2
  @progress_quota_key {__MODULE__, :progress_emit_count}

  defp validate_emit_event_name(name) do
    cond do
      name in @agent_event_exact -> :ok
      Enum.any?(@agent_event_allowlist, &Regex.match?(&1, name)) -> :ok
      true -> {:error, :event_name_not_in_allowlist}
    end
  end

  defp enforce_per_turn_quota("progress") do
    count = Process.get(@progress_quota_key, 0)

    if count >= @progress_emits_per_turn_max do
      {:error, :progress_cap_exceeded}
    else
      Process.put(@progress_quota_key, count + 1)
      :ok
    end
  end

  defp enforce_per_turn_quota(_name), do: :ok

  @doc """
  Reset per-turn vocabulary quotas (currently the `progress` cap). Call this
  at every codex turn boundary so the next turn starts with a fresh budget.
  """
  @spec reset_turn_quotas() :: :ok
  def reset_turn_quotas do
    Process.delete(@progress_quota_key)
    :ok
  end

  defp execute_emit_alert(arguments, opts) do
    alert_emitter = Keyword.get(opts, :alert_emitter)

    with {:ok, name, message, reason, needs_attention, severity} <- normalize_emit_alert_arguments(arguments),
         true <- is_function(alert_emitter, 5) || {:error, :alert_emitter_unavailable},
         :ok <- alert_emitter.(name, message, reason, needs_attention, severity) do
      dynamic_tool_response(
        true,
        Jason.encode!(
          %{
            "ok" => true,
            "name" => name,
            "message" => message,
            "reason" => reason,
            "needs_attention" => needs_attention,
            "severity" => severity
          },
          pretty: true
        )
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
         {:ok, message} <- normalize_emit_alert_string(arguments, "message", :missing_alert_message),
         {:ok, reason} <- normalize_emit_alert_string(arguments, "reason", :missing_alert_reason),
         {:ok, needs_attention} <- normalize_emit_alert_boolean(arguments, "needs_attention", :missing_alert_needs_attention) do
      {:ok, name, message, reason, needs_attention, normalize_emit_alert_severity(arguments, needs_attention)}
    end
  end

  defp normalize_emit_alert_arguments(_arguments), do: {:error, :invalid_alert_arguments}

  defp normalize_emit_alert_string(arguments, key, error_reason) do
    case emit_alert_value(arguments, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, error_reason}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, error_reason}
    end
  end

  defp emit_alert_value(arguments, "name"), do: Map.get(arguments, "name") || Map.get(arguments, :name)
  defp emit_alert_value(arguments, "message"), do: Map.get(arguments, "message") || Map.get(arguments, :message)
  defp emit_alert_value(arguments, "reason"), do: Map.get(arguments, "reason") || Map.get(arguments, :reason)

  defp normalize_emit_alert_boolean(arguments, key, error_reason) do
    value =
      cond do
        Map.has_key?(arguments, key) -> Map.get(arguments, key)
        Map.has_key?(arguments, String.to_atom(key)) -> Map.get(arguments, String.to_atom(key))
        true -> :missing
      end

    case value do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, error_reason}
    end
  end

  defp normalize_emit_alert_severity(arguments, needs_attention) do
    value = Map.get(arguments, "severity") || Map.get(arguments, :severity)

    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default_alert_severity(needs_attention)
          severity -> severity
        end

      _ ->
        default_alert_severity(needs_attention)
    end
  end

  defp default_alert_severity(true), do: "warning"
  defp default_alert_severity(false), do: "info"

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
        "message" => "`emit_alert` expects an object with non-empty `name`, `message`, and `reason` strings plus a boolean `needs_attention`."
      }
    }
  end

  defp tool_error_payload(:missing_alert_name), do: %{"error" => %{"message" => "`emit_alert.name` is required."}}
  defp tool_error_payload(:missing_alert_message), do: %{"error" => %{"message" => "`emit_alert.message` is required."}}
  defp tool_error_payload(:missing_alert_reason), do: %{"error" => %{"message" => "`emit_alert.reason` is required."}}

  defp tool_error_payload(:missing_alert_needs_attention),
    do: %{"error" => %{"message" => "`emit_alert.needs_attention` must be true or false."}}

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

  defp tool_error_payload(:missing_topic_pattern),
    do: %{"error" => %{"message" => "`topic_pattern` is required."}}

  defp tool_error_payload(:invalid_topic_pattern),
    do: %{
      "error" => %{
        "message" => "`topic_pattern` must be non-empty, must not start or end with `.`, and must not contain `..`."
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

  defp tool_error_payload(:missing_issue_number),
    do: %{"error" => %{"message" => "`issue_number` is required."}}

  defp tool_error_payload(:invalid_issue_number),
    do: %{"error" => %{"message" => "`issue_number` must be a positive integer."}}

  defp tool_error_payload(:blocker_declarer_unavailable),
    do: %{"error" => %{"message" => "`aiur_declare_blocker` is unavailable in the current runtime context."}}

  defp tool_error_payload(:unblocker_unavailable),
    do: %{"error" => %{"message" => "`aiur_unblock` is unavailable in the current runtime context."}}

  defp tool_error_payload(:cycle_detected),
    do: %{
      "error" => %{
        "message" => "Declaring this blocker would create a dependency cycle. Resolve the chain before declaring."
      }
    }

  defp tool_error_payload(:blocker_not_found),
    do: %{"error" => %{"message" => "Blocker issue does not exist or is not visible to Aiur's token."}}

  defp tool_error_payload(:rate_limited),
    do: %{"error" => %{"message" => "Cycle pre-check exhausted API budget; retry later."}}

  defp tool_error_payload(:permission_denied),
    do: %{"error" => %{"message" => "Aiur's GitHub token lacks Issues:write scope for this repo."}}

  defp tool_error_payload(:custom_event_quota_exceeded) do
    %{
      "error" => %{
        "message" => "`emit_event` over the per-turn custom.* quota. Wait for the next turn or use a non-`custom.*` name."
      }
    }
  end

  defp tool_error_payload(:progress_cap_exceeded) do
    %{
      "error" => %{
        "message" => "`emit_event` over the per-turn `progress` cap (2 per turn). Wait for the next phase boundary to emit again."
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
        "message" => "Aiur is missing Linear auth. Set `linear.api_key` in `.aiurconfig` or export `LINEAR_API_KEY`."
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

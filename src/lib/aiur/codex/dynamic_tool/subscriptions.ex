defmodule Aiur.Codex.DynamicTool.Subscriptions do
  @moduledoc """
  Dynamic tool handler for `aiur_subscribe` and `aiur_unsubscribe`.
  """

  @behaviour Aiur.Codex.DynamicTool.Handler

  alias Aiur.Codex.DynamicTool.Errors
  alias Aiur.Codex.DynamicTool.Response
  alias Aiur.Events.AgentSubscriptionPolicy

  @aiur_subscribe_description """
  Subscribe the current issue to a topic pattern. Patterns use AMQP topic
  exchange syntax: `*` matches one segment, `#` matches zero or more.
  Manual agent subscriptions must name one literal ticket, for example
  `ticket.42.#` (everything about ticket 42). Executor, system, bare-wildcard,
  and wildcard-ticket bindings are refused.

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
  @aiur_unsubscribe_description """
  Remove a previously-added subscription by exact topic pattern. No-op if
  the pattern was not subscribed.
  """
  @aiur_unsubscribe_input_schema @aiur_subscribe_input_schema

  @impl true
  @spec tools() :: [String.t()]
  def tools, do: ["aiur_subscribe", "aiur_unsubscribe"]

  @impl true
  @spec specs() :: [map()]
  def specs do
    [
      %{
        "name" => "aiur_subscribe",
        "description" => @aiur_subscribe_description,
        "inputSchema" => @aiur_subscribe_input_schema
      },
      %{
        "name" => "aiur_unsubscribe",
        "description" => @aiur_unsubscribe_description,
        "inputSchema" => @aiur_unsubscribe_input_schema
      }
    ]
  end

  @impl true
  @spec execute(String.t(), term(), keyword()) :: map()
  def execute("aiur_subscribe", arguments, opts) do
    execute_subscription(arguments, opts, :subscribe)
  end

  def execute("aiur_unsubscribe", arguments, opts) do
    execute_subscription(arguments, opts, :unsubscribe)
  end

  @spec execute_subscription(term(), keyword(), :subscribe | :unsubscribe) :: map()
  def execute_subscription(arguments, opts, action) do
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
         :ok <- validate_subscription(action, pattern),
         true <- is_function(handler, 1) || {:error, error_atom},
         :ok <- handler.(pattern) do
      Response.build(
        true,
        Jason.encode!(%{"ok" => true, "topic_pattern" => pattern}, pretty: true)
      )
    else
      {:error, reason} ->
        Response.failure(Errors.payload(reason))

      false ->
        Response.failure(Errors.payload(error_atom))
    end
  end

  @spec normalize_topic_pattern(term()) :: {:ok, String.t()} | {:error, atom()}
  def normalize_topic_pattern(arguments) when is_map(arguments) do
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

  def normalize_topic_pattern(_), do: {:error, :invalid_topic_pattern}

  defp validate_subscription(:subscribe, pattern), do: AgentSubscriptionPolicy.validate(pattern)
  defp validate_subscription(:unsubscribe, _pattern), do: :ok
end

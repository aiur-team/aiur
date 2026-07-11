defmodule Aiur.Codex.DynamicTool.EmitEvent do
  @moduledoc """
  Dynamic tool handler for the `emit_event` tool.
  """

  @behaviour Aiur.Codex.DynamicTool.Handler

  alias Aiur.Codex.DynamicTool.Args
  alias Aiur.Codex.DynamicTool.Errors
  alias Aiur.Codex.DynamicTool.Response

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
        "description" =>
          "Optional structured data (e.g. {blocking_issue: 80, function: \"foo\"}). For a decision-blocked `blocked` or `pause.request`, use {reason: \"operator_decision\", question: \"...\"} to raise a durable operator attention.",
        "additionalProperties" => true
      }
    }
  }

  @agent_event_allowlist [
    ~r/\Aprogress\.[a-z0-9][a-z0-9.-]{0,63}\z/,
    ~r/\Adecision\.[a-z0-9][a-z0-9.-]{0,63}\z/,
    ~r/\Aattention\.[a-z0-9][a-z0-9.-]{0,63}\z/,
    ~r/\Acustom\.[a-z0-9][a-z0-9.-]{0,63}\z/
  ]
  @agent_event_exact ["progress", "blocked", "unblocked", "attention.resolved", "pause.request"]

  @progress_emits_per_turn_max 2
  @progress_quota_key {Aiur.Codex.DynamicTool, :progress_emit_count}

  @impl true
  @spec tools() :: [String.t()]
  def tools, do: ["emit_event"]

  @impl true
  @spec specs() :: [map()]
  def specs do
    [
      %{
        "name" => "emit_event",
        "description" => @emit_event_description,
        "inputSchema" => @emit_event_input_schema
      }
    ]
  end

  @impl true
  @spec execute(String.t(), term(), keyword()) :: map()
  def execute("emit_event", arguments, opts) do
    event_publisher = Keyword.get(opts, :event_publisher)

    with {:ok, name, message, payload} <- normalize_emit_event_arguments(arguments),
         :ok <- validate_emit_event_name(name),
         :ok <- enforce_per_turn_quota(name),
         true <- is_function(event_publisher, 3) || {:error, :event_publisher_unavailable},
         {:ok, result} <- event_publisher.(name, message, payload) do
      Response.build(
        true,
        Jason.encode!(
          %{"ok" => true, "name" => name, "message" => message, "result" => result},
          pretty: true
        )
      )
    else
      {:error, reason} ->
        Response.failure(Errors.payload(reason))

      false ->
        Response.failure(Errors.payload(:event_publisher_unavailable))
    end
  end

  @spec normalize_emit_event_arguments(term()) ::
          {:ok, String.t(), String.t(), map()} | {:error, atom()}
  def normalize_emit_event_arguments(arguments) when is_map(arguments) do
    with {:ok, name} <- Args.alert_string(arguments, "name", :missing_event_name),
         {:ok, message} <-
           Args.alert_string(arguments, "message", :missing_event_message) do
      payload =
        case Map.get(arguments, "payload") || Map.get(arguments, :payload) do
          %{} = map -> map
          _ -> %{}
        end

      {:ok, name, message, payload}
    end
  end

  def normalize_emit_event_arguments(_arguments), do: {:error, :invalid_event_arguments}

  @spec validate_emit_event_name(String.t()) :: :ok | {:error, atom()}
  def validate_emit_event_name(name) do
    cond do
      name in @agent_event_exact -> :ok
      Enum.any?(@agent_event_allowlist, &Regex.match?(&1, name)) -> :ok
      true -> {:error, :event_name_not_in_allowlist}
    end
  end

  @spec enforce_per_turn_quota(String.t()) :: :ok | {:error, atom()}
  def enforce_per_turn_quota("progress") do
    count = Process.get(@progress_quota_key, 0)

    if count >= @progress_emits_per_turn_max do
      {:error, :progress_cap_exceeded}
    else
      Process.put(@progress_quota_key, count + 1)
      :ok
    end
  end

  def enforce_per_turn_quota(_name), do: :ok

  @doc """
  Reset per-turn vocabulary quotas (currently the `progress` cap). Call this
  at every codex turn boundary so the next turn starts with a fresh budget.
  """
  @spec reset_turn_quotas() :: :ok
  def reset_turn_quotas do
    Process.delete(@progress_quota_key)
    :ok
  end
end

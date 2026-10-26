defmodule Aiur.AgentTools.EmitEvent do
  @moduledoc """
  Dynamic tool handler for the `emit_event` tool.
  """

  @behaviour Aiur.AgentTools.Handler

  alias Aiur.AgentTools.Args
  alias Aiur.AgentTools.Errors
  alias Aiur.AgentTools.Response
  alias Aiur.AgentTools.StatusNote

  @emit_event_description """
  Emit a cross-ticket Aiur event. Routes onto the `Aiur.Events.Exchange`
  topic exchange where other agents/the Executor can subscribe by
  pattern. The `name` is a scoped vocabulary tag (`progress.<slug>`,
  `decision.<slug>`, `blocked`, `unblocked`, `attention.<slug>`,
  `attention.resolved`, `pause.request`, or `custom.<slug>`). The full
  published topic is `ticket.<your-issue>.agent.<name>`, except
  `optimistic.integrated`, which publishes `ticket.<your-issue>.optimistic.integrated`
  with payload `{blocker, sha, conflict, non_ff}`.

  Subscribers see your `message` and optional structured `payload`. Use
  `emit_event` for coordination signals an agent on another ticket might
  want to react to; use `emit_alert` for Executor-facing audible alerts.
  The exact names `decision.acknowledged` and `decision.resolved` are durable
  target-agent lifecycle events; their payload must carry `decision_id`,
  `action_id`, and `expected_version` from the delivered answer envelope.

  For an Executor answer, including a factual observation, emit
  `decision.requested` with a structured payload. Set `authority` to
  `supervisor_allowed` and `reversibility` to `reversible` when the requested
  answer is an observed fact. `attention.<slug>` only raises visibility; its
  legacy Command is human-required and cannot be answered by the Executor.
  Keep genuine human policy choices `human_required`; include
  `context.authority_basis` as `product`, `spend`, `external_publication`, or
  `security`, with context explaining the specific boundary. Missing or
  unrecognized bases are rejected. Legacy attention projections are exempt.
  """
  @emit_event_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["name", "message"],
    "properties" => %{
      "name" => %{
        "type" => "string",
        "description" =>
          "Vocabulary tag. One of: progress (bare; payload %{percent, label}), progress.status (status note; payload %{doing, why, next, waiting_on, asks, risks, pr, updated_reason}, one-line message ≤200 bytes, payload ≤1,280 bytes, 6 per turn), progress.<slug>, decision.<slug> (decision.acknowledged/resolved require durable correlation payloads), blocked, unblocked, attention.<slug>, attention.resolved, pause.request, custom.<slug>, optimistic.integrated"
      },
      "message" => %{"type" => "string", "description" => "Short human-readable summary."},
      "payload" => %{
        "type" => ["object", "null"],
        "description" =>
          "Optional structured data (e.g. {blocking_issue: 80, function: \"foo\"}). For a decision-blocked `blocked` or `pause.request`, use {reason: \"operator_decision\", question: \"...\"} to raise a durable Executor attention.",
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
  @agent_event_exact ["progress", "blocked", "unblocked", "attention.resolved", "pause.request", "optimistic.integrated"]

  @progress_emits_per_turn_max 2
  @progress_quota_key {Aiur.AgentTools.Dispatch, :progress_emit_count}
  @status_notes_per_turn_max 6
  @status_note_quota_key {Aiur.AgentTools.Dispatch, :status_note_emit_count}

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
         {:ok, message, payload} <- validate_payload(name, message, payload),
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

  @doc false
  @spec topic(String.t() | nil, String.t()) :: String.t()
  def topic(identifier, "optimistic.integrated") when is_binary(identifier), do: "ticket.#{identifier}.optimistic.integrated"
  def topic(nil, name), do: "agent.#{name}"
  def topic(identifier, name), do: "ticket.#{identifier}.agent.#{name}"

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

  def enforce_per_turn_quota("progress.status") do
    count = Process.get(@status_note_quota_key, 0)

    if count >= @status_notes_per_turn_max do
      {:error, :status_note_cap_exceeded}
    else
      Process.put(@status_note_quota_key, count + 1)
      :ok
    end
  end

  def enforce_per_turn_quota(_name), do: :ok

  defp validate_payload("progress.status", message, payload), do: StatusNote.validate(message, payload)
  defp validate_payload(_name, message, payload), do: {:ok, message, payload}

  @doc """
  Reset per-turn vocabulary quotas (the `progress` and `progress.status` caps). Call this
  at every codex turn boundary so the next turn starts with a fresh budget.
  """
  @spec reset_turn_quotas() :: :ok
  def reset_turn_quotas do
    Process.delete(@progress_quota_key)
    Process.delete(@status_note_quota_key)
    :ok
  end
end

defmodule Aiur.Codex.DynamicTool.EmitAlert do
  @moduledoc """
  Dynamic tool handler for the `emit_alert` tool.
  """

  @behaviour Aiur.Codex.DynamicTool.Handler

  alias Aiur.Codex.DynamicTool.Args
  alias Aiur.Codex.DynamicTool.Errors
  alias Aiur.Codex.DynamicTool.Response

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
      "name" => %{
        "type" => "string",
        "description" => "Scoped alert name such as `phase.work.start`."
      },
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

  @impl true
  @spec tools() :: [String.t()]
  def tools, do: ["emit_alert"]

  @impl true
  @spec specs() :: [map()]
  def specs do
    [
      %{
        "name" => "emit_alert",
        "description" => @emit_alert_description,
        "inputSchema" => @emit_alert_input_schema
      }
    ]
  end

  @impl true
  @spec execute(String.t(), term(), keyword()) :: map()
  def execute("emit_alert", arguments, opts) do
    alert_emitter = Keyword.get(opts, :alert_emitter)

    with {:ok, name, message, reason, needs_attention, severity} <-
           normalize_emit_alert_arguments(arguments),
         :ok <-
           call_alert_emitter(alert_emitter, name, message, reason, needs_attention, severity) do
      Response.build(
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
        Response.failure(Errors.payload(reason))
    end
  end

  @spec normalize_emit_alert_arguments(term()) ::
          {:ok, String.t(), String.t(), String.t(), boolean(), String.t()} | {:error, atom()}
  def normalize_emit_alert_arguments(arguments) when is_map(arguments) do
    with {:ok, name} <- Args.alert_string(arguments, "name", :missing_alert_name),
         {:ok, message} <-
           Args.alert_string(arguments, "message", :missing_alert_message),
         {:ok, reason} <- normalize_emit_alert_reason(arguments, message),
         {:ok, needs_attention} <- normalize_emit_alert_needs_attention(arguments) do
      {:ok, name, message, reason, needs_attention, normalize_emit_alert_severity(arguments, needs_attention)}
    end
  end

  def normalize_emit_alert_arguments(_arguments), do: {:error, :invalid_alert_arguments}

  @spec normalize_emit_alert_reason(map(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def normalize_emit_alert_reason(arguments, message) do
    case Args.emit_alert_value(arguments, "reason") do
      nil -> {:ok, message}
      _ -> Args.alert_string(arguments, "reason", :missing_alert_reason)
    end
  end

  @spec normalize_emit_alert_needs_attention(map()) ::
          {:ok, boolean()} | {:error, atom()}
  def normalize_emit_alert_needs_attention(arguments) do
    if Args.has_key?(arguments, "needs_attention") do
      Args.boolean(arguments, "needs_attention", :missing_alert_needs_attention)
    else
      {:ok, false}
    end
  end

  @spec normalize_emit_alert_severity(map(), boolean()) :: String.t()
  def normalize_emit_alert_severity(arguments, needs_attention) do
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

  @spec default_alert_severity(boolean()) :: String.t()
  def default_alert_severity(true), do: "warning"
  def default_alert_severity(false), do: "info"

  @spec call_alert_emitter(term(), String.t(), String.t(), String.t(), boolean(), String.t()) ::
          :ok | {:error, atom()}
  def call_alert_emitter(emitter, name, message, reason, needs_attention, severity)
      when is_function(emitter, 5) do
    emitter.(name, message, reason, needs_attention, severity)
  end

  def call_alert_emitter(emitter, name, message, _reason, _needs_attention, _severity)
      when is_function(emitter, 2) do
    emitter.(name, message)
  end

  def call_alert_emitter(_emitter, _name, _message, _reason, _needs_attention, _severity) do
    {:error, :alert_emitter_unavailable}
  end
end

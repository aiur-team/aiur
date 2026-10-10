defmodule Aiur.Codex.EventHumanizer.WrapperEvents do
  @moduledoc false

  import Aiur.EventHumanizerHelpers

  alias Aiur.Codex.EventHumanizer

  def humanize_wrapper_event("mcp_startup_update", payload) do
    server =
      map_path(payload, ["params", "msg", "server"]) ||
        map_path(payload, [:params, :msg, :server]) || "mcp"

    state =
      map_path(payload, ["params", "msg", "status", "state"]) ||
        map_path(payload, [:params, :msg, :status, :state]) || "updated"

    "mcp startup: #{server} #{state}"
  end

  def humanize_wrapper_event("mcp_startup_complete", _payload), do: "mcp startup complete"
  def humanize_wrapper_event("task_started", _payload), do: "task started"
  def humanize_wrapper_event("user_message", _payload), do: "user message received"

  def humanize_wrapper_event("item_started", payload) do
    case wrapper_payload_type(payload) do
      "token_count" -> humanize_wrapper_event("token_count", payload)
      type when is_binary(type) -> "item started (#{humanize_item_type(type)})"
      _ -> "item started"
    end
  end

  def humanize_wrapper_event("item_completed", payload) do
    case wrapper_payload_type(payload) do
      "token_count" -> humanize_wrapper_event("token_count", payload)
      type when is_binary(type) -> "item completed (#{humanize_item_type(type)})"
      _ -> "item completed"
    end
  end

  def humanize_wrapper_event("agent_message_delta", payload),
    do: EventHumanizer.humanize_streaming_event("agent message streaming", payload)

  def humanize_wrapper_event("agent_message_content_delta", payload),
    do: EventHumanizer.humanize_streaming_event("agent message content streaming", payload)

  def humanize_wrapper_event("agent_reasoning_delta", payload),
    do: EventHumanizer.humanize_streaming_event("reasoning streaming", payload)

  def humanize_wrapper_event("reasoning_content_delta", payload),
    do: EventHumanizer.humanize_streaming_event("reasoning content streaming", payload)

  def humanize_wrapper_event("agent_reasoning_section_break", _payload), do: "reasoning section break"

  def humanize_wrapper_event("agent_reasoning", payload) do
    value = EventHumanizer.extract_first_path(payload, reasoning_focus_paths())

    if is_binary(value) do
      trimmed = String.trim(value)
      if trimmed == "", do: "reasoning update", else: "reasoning update: #{inline_text(trimmed)}"
    else
      "reasoning update"
    end
  end

  def humanize_wrapper_event("turn_diff", _payload), do: "turn diff updated"

  def humanize_wrapper_event("exec_command_begin", payload) do
    command =
      map_path(payload, ["params", "msg", "command"]) ||
        map_path(payload, [:params, :msg, :command]) ||
        map_path(payload, ["params", "msg", "parsed_cmd"]) ||
        map_path(payload, [:params, :msg, :parsed_cmd])

    command = EventHumanizer.normalize_command(command)
    if is_binary(command), do: command, else: "command started"
  end

  def humanize_wrapper_event("exec_command_end", payload) do
    exit_code =
      map_path(payload, ["params", "msg", "exit_code"]) ||
        map_path(payload, [:params, :msg, :exit_code]) ||
        map_path(payload, ["params", "msg", "exitCode"]) ||
        map_path(payload, [:params, :msg, :exitCode])

    if is_integer(exit_code), do: "command completed (exit #{exit_code})", else: "command completed"
  end

  def humanize_wrapper_event("exec_command_output_delta", _payload), do: "command output streaming"
  def humanize_wrapper_event("mcp_tool_call_begin", _payload), do: "mcp tool call started"
  def humanize_wrapper_event("mcp_tool_call_end", _payload), do: "mcp tool call completed"

  def humanize_wrapper_event("token_count", payload) do
    usage = EventHumanizer.extract_first_path(payload, token_usage_paths())

    case Aiur.TokenUsage.format_counts(usage) do
      nil -> "token count update"
      usage_text -> "token count update (#{usage_text})"
    end
  end

  def humanize_wrapper_event(other, payload) do
    msg_type =
      map_path(payload, ["params", "msg", "type"]) ||
        map_path(payload, [:params, :msg, :type])

    if is_binary(msg_type), do: "#{other} (#{msg_type})", else: other
  end

  defp wrapper_payload_type(payload) do
    map_path(payload, ["params", "msg", "type"]) ||
      map_path(payload, [:params, :msg, :type]) ||
      map_path(payload, ["params", "msg", "payload", "type"]) ||
      map_path(payload, [:params, :msg, :payload, :type])
  end

  defp token_usage_paths do
    [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total]
    ]
  end

  defp reasoning_focus_paths do
    [
      ["params", "reason"],
      [:params, :reason],
      ["params", "summaryText"],
      [:params, :summaryText],
      ["params", "summary"],
      [:params, :summary],
      ["params", "text"],
      [:params, :text],
      ["params", "msg", "reason"],
      [:params, :msg, :reason],
      ["params", "msg", "summaryText"],
      [:params, :msg, :summaryText],
      ["params", "msg", "summary"],
      [:params, :msg, :summary],
      ["params", "msg", "text"],
      [:params, :msg, :text],
      ["params", "msg", "payload", "reason"],
      [:params, :msg, :payload, :reason],
      ["params", "msg", "payload", "summaryText"],
      [:params, :msg, :payload, :summaryText],
      ["params", "msg", "payload", "summary"],
      [:params, :msg, :payload, :summary],
      ["params", "msg", "payload", "text"],
      [:params, :msg, :payload, :text]
    ]
  end
end

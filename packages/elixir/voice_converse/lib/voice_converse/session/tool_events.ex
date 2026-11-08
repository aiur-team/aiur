defmodule VoiceConverse.Session.ToolEvents do
  @moduledoc false
  alias VoiceConverse.{Events, Redact}

  def redact_tool_call(state, %Events.ToolCall{name: "propose_instruction", params: params} = event) do
    %{event | params: Map.update(params, "text", "", &redact_text(state, &1))}
  end

  def redact_tool_call(state, %Events.ToolCall{name: "ask_agent", params: params} = event),
    do: %{event | params: VoiceConverse.Session.Consult.redact_question(state, params)}

  def redact_tool_call(state, event), do: %{event | params: Redact.redact_value(event.params, state.config.redactor)}

  defp redact_text(state, text) when is_binary(text), do: state.config.redactor.(text)
  defp redact_text(_state, text), do: text

  def handle(state, %Events.ToolCall{name: "propose_instruction", params: params}),
    do: VoiceConverse.Session.DraftTool.instruction(state, params)

  def handle(state, %Events.ToolCall{name: "ask_agent", params: params}),
    do: VoiceConverse.Session.Consult.tool(state, params)

  def handle(state, event), do: {VoiceConverse.Tools.handle(state, event), state}
end

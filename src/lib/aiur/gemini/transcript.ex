defmodule Aiur.Gemini.Transcript do
  @moduledoc "Render attributable ACP updates and permission choices in Aiur's transcript."

  alias Aiur.AgentEvents

  @spec extract(map(), term()) :: {:ok, map()} | :skip
  def extract(%{payload: %{"method" => "session/update", "params" => %{"update" => update}}} = message, fallback)
      when is_map(update) do
    event_for_update(update, message, fallback)
  end

  def extract(%{payload: %{"method" => "session/request_permission", "params" => params}} = message, fallback) do
    options =
      (params["options"] || [])
      |> Enum.filter(&match?(%{"optionId" => id, "name" => name} when is_binary(id) and is_binary(name), &1))
      |> Enum.map_join("\n", fn option ->
        "#{option["name"]}: /approve #{message[:gemini_permission_token]} #{option["optionId"]}"
      end)

    title = get_in(params, ["toolCall", "title"]) || "a Gemini tool"
    body = "Gemini needs approval for #{title}. Reply with one choice:\n#{options}"
    {:ok, event(:system, body, message, fallback, %{approval: params})}
  end

  def extract(_message, _fallback), do: :skip

  defp event_for_update(%{"sessionUpdate" => kind, "content" => %{"type" => "text", "text" => text}}, message, fallback)
       when kind in ["agent_message_chunk", "agent_thought_chunk"] and is_binary(text) and text != "" do
    role = if kind == "agent_thought_chunk", do: :reasoning, else: :assistant
    event = event(role, text, message, fallback, nil)
    {:ok, if(role == :assistant, do: Map.put(event, :kind, :assistant_delta), else: event)}
  end

  defp event_for_update(%{"sessionUpdate" => kind} = update, message, fallback)
       when kind in ["tool_call", "tool_call_update"] do
    title = update["title"] || update["name"] || "Gemini tool"
    body = AgentEvents.tool_call_body(title, update["rawInput"] || %{})
    payload = %{title: title, tool: update["name"], arguments: update["rawInput"], output: update["rawOutput"] || update["content"], status: update["status"]}
    {:ok, event(:tool, body, message, fallback, payload)}
  end

  defp event_for_update(_update, _message, _fallback), do: :skip

  defp event(role, body, message, fallback, payload) do
    update = get_in(message, [:payload, "params", "update"]) || %{}

    AgentEvents.transcript_event(role, body,
      timestamp: message[:timestamp],
      msg_id: update["messageId"] || update["toolCallId"] || message[:gemini_permission_token],
      turn_id: message[:gemini_turn_id] || fallback,
      payload: payload
    )
  end
end

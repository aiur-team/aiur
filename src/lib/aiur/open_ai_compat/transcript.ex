defmodule Aiur.OpenAICompat.Transcript do
  @moduledoc """
  Extracts provider-neutral transcript events from the normalized
  `Aiur.OpenAICompat.CodingAgent` event stream.
  """

  alias Aiur.AgentEvents

  @spec extract(map(), String.t() | nil) :: {:ok, AgentEvents.transcript_event()} | :skip
  def extract(%{event: :assistant, payload: %{text: text} = payload} = event, turn_id)
      when is_binary(text) and text != "" do
    {:ok, AgentEvents.transcript_event(:assistant, text, common_opts(event, payload, turn_id))}
  end

  def extract(%{event: :reasoning, payload: %{text: text} = payload} = event, turn_id)
      when is_binary(text) and text != "" do
    {:ok, AgentEvents.transcript_event(:reasoning, text, common_opts(event, payload, turn_id))}
  end

  def extract(%{event: :tool_call, payload: %{name: "exec_command", arguments: %{"command" => command}} = payload} = event, turn_id)
      when is_binary(command) do
    transcript_payload = %{command: command, output: "", title: command, workdir: payload.arguments["workdir"] || ""}
    {:ok, AgentEvents.transcript_event(:command, command, common_opts(event, payload, turn_id, transcript_payload))}
  end

  def extract(%{event: :tool_call, payload: %{name: name} = payload} = event, turn_id) when is_binary(name) do
    arguments = payload[:arguments] || %{}
    body = Aiur.AgentEvents.tool_call_body(name, arguments)
    transcript_payload = %{tool: name, input: arguments, output: "", title: name}
    {:ok, AgentEvents.transcript_event(:tool, body, common_opts(event, payload, turn_id, transcript_payload))}
  end

  # The tool_call row already carries the command or path, and opencode renders
  # one row per tool (muted once complete) rather than a second "result" row. A
  # separate tool_result transcript row would only repeat the bare tool name
  # (`tool read file`), so it is skipped here rather than persisted into the
  # Stream Deck feed. The opencode conversation state is updated separately in
  # `Aiur.OpenAICompat.CodingAgent`, so nothing downstream of that is affected.
  def extract(%{event: :tool_result, payload: %{name: _name, output: _output}}, _turn_id), do: :skip

  def extract(_event, _turn_id), do: :skip

  defp common_opts(event, payload, turn_id, transcript_payload \\ nil) do
    [
      timestamp: Map.get(event, :timestamp) || DateTime.utc_now(),
      turn_id: turn_id,
      msg_id: payload[:id],
      payload: transcript_payload
    ]
  end
end

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
    transcript_payload = %{tool: name, input: payload[:arguments] || %{}, output: "", title: name}
    {:ok, AgentEvents.transcript_event(:tool, name, common_opts(event, payload, turn_id, transcript_payload))}
  end

  def extract(%{event: :tool_result, payload: %{name: name, output: output} = payload} = event, turn_id)
      when is_binary(name) and is_binary(output) do
    title = if payload[:success] == false, do: "#{name} (error)", else: name
    transcript_payload = %{tool: name, input: %{}, output: output, title: title, success: payload[:success]}
    {:ok, AgentEvents.transcript_event(:tool, title, common_opts(event, payload, turn_id, transcript_payload))}
  end

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

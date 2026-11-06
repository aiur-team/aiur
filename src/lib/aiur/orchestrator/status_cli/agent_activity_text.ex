defmodule Aiur.Orchestrator.StatusCLI.AgentActivityText do
  @moduledoc """
  One short activity line for an in-process backend's normalized worker event.

  Codex and Claude report activity as app-server payloads carrying a `method`,
  which `Aiur.Codex.EventHumanizer` renders. The in-process OpenAI-compatible
  backends (OpenRouter, DeepSeek, Kimi) instead emit their own normalized
  events -- `:tool_call`, `:assistant`, `:reasoning`, `:turn_completed` -- with
  no `method` at all, so the fleet views had nothing to print for a worker that
  was busy (#7506). The rendering lives here, in the fleet-view component,
  rather than in the backend: `aiur agents` already owns how every backend's
  activity reads, and the backend's job is only to emit the events.
  """

  alias Aiur.AgentEvents

  @doc """
  One short activity line for a normalized worker event, or `nil` when the
  message is not one this renderer understands.

  The status report holds each worker update as
  `%{event: event, message: payload, timestamp: timestamp}`, so the payload is
  read out of that envelope exactly as the app-server path reads it. Streaming
  text stays out of the line: an assistant message is only useful once it is a
  whole message, and a reasoning event says the model is thinking without
  claiming what about.
  """
  @spec describe(term()) :: String.t() | nil
  def describe(%{event: :session_started}), do: "turn started"
  def describe(%{event: :turn_completed}), do: "turn completed"
  def describe(%{event: :reasoning}), do: "thinking"

  def describe(%{event: :tool_call, message: %{name: name} = payload}) when is_binary(name) do
    case command(payload) do
      nil -> AgentEvents.tool_call_body(name, arguments(payload))
      command -> "run #{one_line(command)}"
    end
  end

  def describe(%{event: :assistant, message: %{text: text}}) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: one_line(text)
  end

  def describe(_message), do: nil

  defp one_line(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp arguments(%{arguments: arguments}) when is_map(arguments), do: arguments
  defp arguments(_payload), do: %{}

  defp command(payload) do
    case arguments(payload) do
      %{"command" => command} when is_binary(command) -> command
      %{command: command} when is_binary(command) -> command
      _arguments -> nil
    end
  end
end

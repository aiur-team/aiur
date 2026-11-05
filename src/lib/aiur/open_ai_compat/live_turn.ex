defmodule Aiur.OpenAICompat.LiveTurn do
  @moduledoc """
  Live-turn signals for the in-process OpenAI-compatible backends (#7506).

  Codex and Claude workers report a turn to the orchestrator as three things:
  a session start carrying the session id, the activity messages that follow
  it, and a completion. `Aiur.Orchestrator.StatusReport.RowFacts.startup_work_state/1`
  derives `work_state: :starting` -- rendered as "starting provider; no live
  turn yet" by `aiur agents` -- from a running entry that has no `session_id`,
  so a backend that never sends the session start stays `:starting` for its
  whole turn however busy it is. `Aiur.Orchestrator.WaitingReason.unresponsive?/1`
  then never classifies such a row as stalled either, because it only fires for
  `:working` or `:sleeping`.

  This module builds those signals for the OpenAI-compatible backend and
  renders its normalized activity events for the fleet views. The turn start
  carries no app-server `method`: these backends are not app-server sessions,
  and the payload only needs the identity the orchestrator keys a live turn on.
  """

  import Aiur.EventHumanizerHelpers, only: [inline_text: 1]

  alias Aiur.AgentEvents

  @type identity :: %{
          session_id: String.t(),
          thread_id: String.t(),
          turn_id: String.t()
        }

  @doc """
  The identity of the turn a session agent state is currently running.

  `session_id` follows the app-server shape (`<thread_id>-<turn_id>`) so the
  orchestrator's turn accounting, which counts a new `:session_started` session
  id as a turn, treats these backends the same way.
  """
  @spec identity(map()) :: identity()
  def identity(%{thread_id: thread_id} = state) when is_binary(thread_id) do
    turn_id = Integer.to_string(Map.get(state, :turn_index, 0))
    %{session_id: "#{thread_id}-#{turn_id}", thread_id: thread_id, turn_id: turn_id}
  end

  @doc "The turn-start update the orchestrator keys a live turn on."
  @spec started(identity()) :: map()
  def started(identity), do: Map.put(identity, :event, :session_started)

  @doc "The turn-end update for the completion that ended `identity`'s turn."
  @spec completed(map(), identity()) :: map()
  def completed(%{id: completion_id}, identity) do
    identity
    |> Map.put(:event, :turn_completed)
    |> Map.put(:payload, %{id: completion_id})
  end

  @doc """
  One short activity line for a normalized OpenAI-compatible event, or `nil`
  when the message is not one of this backend's events.

  The status report holds each worker update as
  `%{event: event, message: payload, timestamp: timestamp}`, so the payload is
  read out of that envelope exactly as `aiur agents` reads it for the
  app-server backends. Streaming text stays out of the line: an assistant
  message is only useful once it is a whole message, and a reasoning event says
  the model is thinking without claiming what about.
  """
  @spec describe(term()) :: String.t() | nil
  def describe(%{event: :session_started}), do: "turn started"
  def describe(%{event: :turn_completed}), do: "turn completed"
  def describe(%{event: :reasoning}), do: "thinking"

  def describe(%{event: :tool_call, message: %{name: name} = payload}) when is_binary(name) do
    case command(payload) do
      nil -> AgentEvents.tool_call_body(name, arguments(payload))
      command -> "run #{inline_text(command)}"
    end
  end

  def describe(%{event: :assistant, message: %{text: text}}) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: inline_text(text)
  end

  def describe(_message), do: nil

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

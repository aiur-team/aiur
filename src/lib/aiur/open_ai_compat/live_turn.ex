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

  This module builds those signals. The turn start carries no app-server
  `method`: these backends are not app-server sessions, and the payload only
  needs the identity the orchestrator keys a live turn on. How that activity is
  rendered for the fleet views is
  `Aiur.Orchestrator.StatusCLI.AgentActivityText`'s job, not this module's.
  """

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
end

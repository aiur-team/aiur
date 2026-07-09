defmodule Aiur.AgentRunner.TurnStreams do
  @moduledoc """
  Coordinates Opencode bridge streams for a single agent turn.

  It registers active turns before marker fan-out and emits the matching
  completion broadcast when the turn closes.
  """

  alias Aiur.{AgentPubSub, Issue}
  alias Aiur.Opencode.{ActiveTurns, ApiClient, SessionWriterRegistry, TurnMarkers}

  @spec open(Issue.t()) :: String.t() | nil
  def open(%Issue{identifier: identifier}) when is_binary(identifier) do
    aiur_turn_id = "t" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
    # Register BEFORE posting so the bridge always observes :active when
    # it handles the resulting chat-completion. Stale markers replayed
    # by opencode-serve from a previous boot will be absent from the
    # table and the bridge will close them as phantom.
    :ok = ActiveTurns.put(identifier, aiur_turn_id)

    writers = SessionWriterRegistry.attached(identifier)
    :ok = post_aiur_turn_markers(identifier, aiur_turn_id, writers)

    aiur_turn_id
  end

  def open(_issue), do: nil

  @doc """
  Fire `__aiur_turn__:<id>` marker posts to every attached opencode-serve.
  Delegates to `Aiur.Opencode.TurnMarkers.post_all/4`, which also serves the
  bridge's continuation markers (segmented turn streams).
  """
  @spec post_aiur_turn_markers(
          String.t(),
          String.t(),
          [%{session_id: String.t(), base_url: String.t()}],
          (String.t(), String.t(), map() -> {:ok, term()} | {:error, term()})
        ) :: :ok
  def post_aiur_turn_markers(identifier, aiur_turn_id, writers, post_fn \\ &ApiClient.post_message/3) do
    TurnMarkers.post_all(identifier, aiur_turn_id, writers, post_fn)
  end

  @spec close(Issue.t(), String.t() | nil, term()) :: :ok
  def close(%Issue{identifier: identifier}, aiur_turn_id, reason)
      when is_binary(identifier) and is_binary(aiur_turn_id) do
    AgentPubSub.broadcast_aiur_turn_done(identifier, aiur_turn_id, reason)
    # mark_closed retains the entry for the cleanup window so a slow
    # bridge subscribe still finalizes with this reason instead of
    # waiting on the broadcast it missed.
    ActiveTurns.mark_closed(identifier, aiur_turn_id, reason)
    :ok
  end

  def close(_issue, _aiur_turn_id, _reason), do: :ok
end

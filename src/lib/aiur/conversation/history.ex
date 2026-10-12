defmodule Aiur.Conversation.History do
  @moduledoc """
  Read-only access to live conversations, workspace transcripts and observed anchors.

  Keeps the existing stores' results and failures unchanged. Live conversation
  writes remain owned by the agent runner.
  """

  alias Aiur.{AgentEventFeed, AgentLog, LiveConversation}
  alias Aiur.Conversation.Anchors

  defdelegate live_resolve(handle), to: LiveConversation, as: :resolve
  defdelegate live_subscribe(handle), to: LiveConversation, as: :subscribe_handle
  defdelegate live_unsubscribe(handle), to: LiveConversation, as: :unsubscribe_handle
  defdelegate transcript(identifier, params), to: AgentEventFeed, as: :list
  defdelegate bus_events(identifier), to: AgentEventFeed
  defdelegate bus_events(identifier, opts), to: AgentEventFeed
  defdelegate workspace_log(workspace), to: AgentLog, as: :read_workspace
  defdelegate read_log(path), to: AgentLog, as: :read
  defdelegate parse_log(content), to: AgentLog, as: :parse
  defdelegate workspace_log_path(workspace), to: AgentLog
  defdelegate anchor(events, entries), to: Anchors, as: :at_or_before
  defdelegate load_anchors(events, entries), to: Anchors, as: :with_origin
end

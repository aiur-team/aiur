defmodule Aiur.Conversation.History do
  @moduledoc """
  Read-only access to live conversations, workspace transcripts and observed anchors.

  Keeps the existing stores' results and failures unchanged. Live conversation
  writes remain owned by the agent runner.
  """

  alias Aiur.AgentEventFeed
  alias Aiur.AgentLog
  alias Aiur.AgentLog.PageReader
  alias Aiur.Conversation.Anchors
  alias Aiur.LiveConversation

  @spec log_tail(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def log_tail(path, opts \\ []), do: PageReader.tail(path, opts)

  @spec log_before(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def log_before(path, cursor, opts \\ []), do: PageReader.before(path, cursor, opts)

  @spec log_since(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def log_since(path, cursor, opts \\ []), do: PageReader.since(path, cursor, opts)

  @spec structured_entry(String.t()) :: map() | nil
  def structured_entry(line), do: AgentLog.structured_entry(line)

  @spec workspace_paged_tail(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def workspace_paged_tail(workspace, opts \\ []), do: log_tail(AgentLog.workspace_structured_log_path(workspace), opts)

  @spec workspace_paged_before(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def workspace_paged_before(workspace, cursor, opts \\ []), do: log_before(AgentLog.workspace_structured_log_path(workspace), cursor, opts)

  @spec workspace_paged_since(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def workspace_paged_since(workspace, cursor, opts \\ []), do: log_since(AgentLog.workspace_structured_log_path(workspace), cursor, opts)

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

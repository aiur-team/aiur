defmodule Aiur.IssueLog.EventHistorySink do
  @moduledoc "Default event-marker sink, preserving IssueLog's asynchronous writes."
  @behaviour Aiur.Events.HistoryStore

  @impl true
  def record(identifier, kind, event), do: Aiur.IssueLog.record_event(identifier, kind, event)
end

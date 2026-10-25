defmodule Aiur.DecisionStore.Async do
  @moduledoc false

  @spec consume_pending_for_session_async(String.t(), String.t(), [String.t()], GenServer.server()) :: :ok
  def consume_pending_for_session_async(ticket_identifier, session_id, action_ids, server) do
    GenServer.cast(server, {:consume_pending_for_session, ticket_identifier, session_id, action_ids})
  catch
    :exit, _reason -> :ok
  end
end

defmodule Aiur.Orchestrator.Lifecycle.StalledAlert do
  @moduledoc false

  alias Aiur.Orchestrator.State

  @spec clear_retry_marker(State.t(), term(), map()) :: State.t()
  def clear_retry_marker(%State{running: running} = state, issue_id, running_entry) do
    updated = Map.put(running_entry, :stalled_alert_outstanding, false)
    %{state | running: Map.put(running, issue_id, updated)}
  end
end

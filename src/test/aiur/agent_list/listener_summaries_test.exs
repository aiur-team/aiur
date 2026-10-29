defmodule Aiur.AgentList.ListenerSummariesTest do
  use ExUnit.Case, async: false
  alias Aiur.{AgentQueue, AgentQueueStore, Issue}
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReport.RunningSummaries

  test "fleet summary carries authoritative mode and held count, then clears count after read" do
    issue = %Issue{id: "issue-42", identifier: "42", title: "Working", state: "in-progress"}
    view = %{effective: :sync, requested: :steer, effective_reason: :steer_not_wired, version: 2}
    entry = %{identifier: "42", issue: issue, listener_effective: view}
    {store, held} = AgentQueueStore.enqueue(AgentQueueStore.new(), AgentQueue.operator_message("42", "held", listener_mode: :async))
    state = %State{candidate_snapshot_fresh?: false, running: %{issue.id => entry}, queue_store: store}
    assert [%{listener: listener}] = RunningSummaries.running_summaries(state, spec_status: :ok)
    assert listener == Map.merge(view, %{unread_count: 1, oldest_unread_at: held.inserted_at})
    assert [unavailable] = RunningSummaries.running_summaries(state, spec_status: {:error, :spec_invalid})
    refute Map.has_key?(unavailable, :listener)
    {store, _} = AgentQueueStore.mark_consumed(store, held.id)
    assert [%{listener: %{unread_count: 0, oldest_unread_at: nil}}] = RunningSummaries.running_summaries(%{state | queue_store: store}, spec_status: :ok)
  end
end

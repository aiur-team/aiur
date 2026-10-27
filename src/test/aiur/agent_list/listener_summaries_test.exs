defmodule Aiur.AgentList.ListenerSummariesTest do
  use ExUnit.Case, async: false
  alias Aiur.{AgentQueue, AgentQueueStore, Issue}
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReport.RunningSummaries

  setup do
    previous = Application.fetch_env(:aiur, :listener_send_routing)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :listener_send_routing, value)
        :error -> Application.delete_env(:aiur, :listener_send_routing)
      end
    end)

    :ok
  end

  test "fleet summary carries authoritative mode and held count, then clears count after read" do
    Application.put_env(:aiur, :listener_send_routing, :listener)
    issue = %Issue{id: "issue-42", identifier: "42", title: "Working", state: "in-progress"}
    view = %{effective: :sync, requested: :steer, effective_reason: :steer_not_wired, version: 2}
    entry = %{identifier: "42", issue: issue, listener_effective: view}
    {store, held} = AgentQueueStore.enqueue(AgentQueueStore.new(), AgentQueue.operator_message("42", "held", listener_mode: :async))
    state = %State{candidate_snapshot_fresh?: false, running: %{issue.id => entry}, queue_store: store}
    assert [%{listener: listener}] = RunningSummaries.running_summaries(state, spec_status: :ok)
    assert listener == Map.merge(view, %{unread_count: 1, oldest_unread_at: held.inserted_at})
    {store, _} = AgentQueueStore.mark_consumed(store, held.id)
    assert [%{listener: %{unread_count: 0, oldest_unread_at: nil}}] = RunningSummaries.running_summaries(%{state | queue_store: store}, spec_status: :ok)
    Application.put_env(:aiur, :listener_send_routing, :legacy)
    assert [legacy] = RunningSummaries.running_summaries(state, spec_status: :ok)
    refute Map.has_key?(legacy, :listener)
  end
end

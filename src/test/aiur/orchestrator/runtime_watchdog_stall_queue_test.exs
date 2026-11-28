defmodule Aiur.Orchestrator.RuntimeWatchdogStallQueueTest do
  use Aiur.TestSupport

  alias Aiur.{AgentQueue, AgentQueueStore, Issue}
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.RuntimeWatchdog

  # open-games #644: the Executor's rework notes reached a Claude session that
  # then hung. The stall kill left the item delivered, so the retry and the
  # redispatch after the claim release never received the notes.
  test "a stall restart puts messages handed to the hung session back for the retry" do
    issue_id = "issue-stall-queue"
    identifier = "STALL-Q"
    stale_at = DateTime.add(DateTime.utc_now(), -600, :second)

    {store, item} = AgentQueueStore.enqueue(AgentQueueStore.new(), AgentQueue.operator_message(identifier, "Rework: trailers must be 16:9, gameplay only."))
    {store, %{status: :delivered}} = AgentQueueStore.claim_next_deliverable(store, identifier)
    {store, _item} = AgentQueueStore.mark_provider_delivered(store, item.id, %{turn_id: "turn-1"})

    worker_pid = start_supervised!({Task, fn -> receive(do: (:stop -> :ok)) end})

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: worker_pid,
          ref: nil,
          identifier: identifier,
          issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
          started_at: stale_at,
          last_codex_timestamp: stale_at,
          session_execution: %{backend: "claude"},
          control: %{status: :working}
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{},
      max_concurrent_agents: 6,
      queue_store: store
    }

    next = RuntimeWatchdog.apply_stall_check(state, 1)

    refute Map.has_key?(next.running, issue_id)
    assert %{error: "stalled" <> _} = next.retry_attempts[issue_id]
    assert %{status: :pending, provider_delivered_at: nil} = AgentQueueStore.get(next.queue_store, item.id)
    assert {_store, %{id: id}} = AgentQueueStore.claim_next_deliverable(next.queue_store, identifier)
    assert id == item.id
  end
end

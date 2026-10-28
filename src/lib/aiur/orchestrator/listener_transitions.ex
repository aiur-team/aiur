defmodule Aiur.Orchestrator.ListenerTransitions do
  @moduledoc "Count-only async backlog notices; called by serialized mode control."

  alias Aiur.{AgentQueue, AgentQueueStore}
  alias Aiur.Listener.Scheduler
  alias Aiur.Orchestrator.OperatorMessages.Unread

  @spec on_change(AgentQueueStore.t(), String.t(), map(), map()) :: {AgentQueueStore.t(), map() | nil}
  def on_change(store, identifier, previous, current) do
    cond do
      current.version <= previous.version -> {store, nil}
      current.requested == :async -> {supersede_notices(store, identifier), nil}
      previous.requested == :async and current.requested in [:sync, :steer] -> notice(store, identifier, current)
      true -> {store, nil}
    end
  end

  defp notice(store, identifier, current) do
    count = Unread.queue_summary(store, identifier).listener.unread_count

    if count == 0 do
      {store, nil}
    else
      attrs =
        AgentQueue.operator_message(identifier, "#{count} earlier messages are waiting; read them with aiur_read_messages", listener_mode: :sync)
        |> Map.merge(%{
          source: :system,
          category: :system_notice,
          event_type: :async_backlog_notice,
          message_id: "async-backlog:#{identifier}:#{current.version}",
          dedupe_key: "async-backlog:#{identifier}"
        })
        |> Map.update!(:delivery, Scheduler.restamp_fun(current))

      {:ok, store, _item, _outcome} = AgentQueueStore.enqueue_idempotent(store, attrs)
      {store, %{rule: :notice, count: count}}
    end
  end

  defp supersede_notices(store, identifier) do
    store
    |> AgentQueueStore.list_pending(identifier)
    |> Enum.reduce(store, fn
      %{category: :system_notice, event_type: :async_backlog_notice, id: id}, acc ->
        {acc, _} = AgentQueueStore.mark_superseded(acc, id)
        acc

      _item, acc ->
        acc
    end)
  end
end

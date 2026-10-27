defmodule Aiur.Orchestrator.OperatorMessages.Unread do
  @moduledoc "Queue-derived held-message counts shared by control projection and change signals."

  alias Aiur.{AgentEvents, AgentPubSub, AgentQueueStore}

  @spec queue_summary(AgentQueueStore.t(), String.t()) :: map()
  def queue_summary(store, identifier) do
    store
    |> AgentQueueStore.list_pending(identifier)
    |> Enum.reduce(%{queue_depth: 0, listener: %{unread_count: 0, oldest_unread_at: nil}}, fn item, acc ->
      acc = %{acc | queue_depth: acc.queue_depth + 1}
      if held?(item), do: %{acc | listener: add_unread(acc.listener, item.inserted_at)}, else: acc
    end)
  end

  @spec broadcast_change(AgentQueueStore.t(), AgentQueueStore.t(), String.t()) :: :ok
  def broadcast_change(previous, current, identifier) do
    before = queue_summary(previous, identifier).listener
    after_read = queue_summary(current, identifier).listener

    if before != after_read do
      AgentPubSub.broadcast_transcript(
        identifier,
        AgentEvents.transcript_event(:system, "Unread held messages changed", payload: %{listener: after_read})
      )
    end

    :ok
  end

  defp held?(%{status: :pending, category: :operator_message, delivery: %{consume_at: :pull}}), do: true
  defp held?(_item), do: false

  defp add_unread(summary, inserted_at) do
    oldest = summary.oldest_unread_at
    oldest = if is_nil(oldest) or DateTime.before?(inserted_at, oldest), do: inserted_at, else: oldest
    %{unread_count: summary.unread_count + 1, oldest_unread_at: oldest}
  end
end

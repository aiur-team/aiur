defmodule Aiur.Orchestrator.OperatorMessages.HeldReads do
  @moduledoc "Serialized consuming reads; acknowledgement is recorded before returning the batch."
  alias Aiur.{AgentEvents, AgentPubSub, AgentQueueStore}
  alias Aiur.AgentQueueStore.Items
  alias Aiur.Listener.ModeStore
  alias Aiur.Orchestrator.LifecycleFence
  alias Aiur.Orchestrator.OperatorMessages.Unread

  @spec read(GenServer.server(), String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def read(server, identifier, max) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    # Do not abandon a consuming call: a caller timeout does not cancel GenServer work.
    GenServer.call(server, {:read_held_messages, identifier, max, deadline}, :infinity)
  catch
    :exit, reason -> {:error, {:read_unavailable, reason}}
  end

  @spec handle_call(Aiur.Orchestrator.State.t(), String.t(), pos_integer(), keyword()) :: tuple()
  def handle_call(state, identifier, max, opts \\ [])

  def handle_call(state, identifier, max, opts) when is_binary(identifier) and max in 1..50 do
    held = state.queue_store |> AgentQueueStore.list_pending(identifier) |> Enum.filter(&held?/1)
    {items, messages} = batch(held, max)

    with :ok <- before_deadline(opts),
         :ok <- persist_cursor(identifier, items, opts) do
      now = DateTime.utc_now()
      store = Enum.reduce(items, state.queue_store, &consume(&2, &1, now))
      if items != [], do: broadcast(identifier, items, now)
      Unread.broadcast_change(state.queue_store, store, identifier)
      next = Enum.reduce(items, %{state | queue_store: store}, &LifecycleFence.acknowledge_provider_delivery(&2, &1))
      {:reply, {:ok, %{messages: messages, remaining: length(held) - length(items)}}, next}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(state, _identifier, _max, _opts), do: {:reply, {:error, :invalid_arguments}, state}

  defp before_deadline(opts) do
    case Keyword.get(opts, :deadline) do
      nil -> :ok
      deadline -> if System.monotonic_time(:millisecond) < deadline, do: :ok, else: {:error, :read_timeout}
    end
  end

  defp held?(%{status: :pending, category: :operator_message, delivery: %{consume_at: :pull}}), do: true
  defp held?(_item), do: false

  defp batch(held, max) do
    held
    |> Enum.take(max)
    |> Enum.reduce_while({[], [], 65_536}, fn item, {items, messages, budget} ->
      text = item.body.text
      clipped = clip(text, budget)
      message = %{id: item.id, text: clipped, from: sender(item), accepted_at: DateTime.to_iso8601(item.inserted_at)}
      message = if byte_size(text) > budget, do: Map.put(message, :truncated, true), else: message
      result = {[item | items], [message | messages], budget - byte_size(clipped)}
      if byte_size(text) >= budget, do: {:halt, result}, else: {:cont, result}
    end)
    |> then(fn {items, messages, _} -> {Enum.reverse(items), Enum.reverse(messages)} end)
  end

  defp clip(text, budget) when byte_size(text) <= budget, do: text

  defp clip(text, budget) do
    prefix = binary_part(text, 0, budget)
    # A byte boundary may fall inside the final UTF-8 codepoint.
    if String.valid?(prefix), do: prefix, else: clip(prefix, budget - 1)
  end

  defp sender(%{source: :operator}), do: "operator"
  defp sender(_item), do: "executor"

  defp persist_cursor(_identifier, [], _opts), do: :ok
  defp persist_cursor(identifier, items, opts), do: ModeStore.record_read(identifier, List.last(items).sequence, opts)

  defp consume(store, item, now) do
    read = %{item | status: :consumed, read_at: now, consumed_at: now, failure_reason: nil}
    store |> Items.put_item(read) |> Items.remove_pending_id(item.target_issue_identifier, item.id)
  end

  defp broadcast(identifier, items, now) do
    AgentPubSub.broadcast_transcript(
      identifier,
      AgentEvents.transcript_event(:system, "Held messages read", payload: %{operator_message: %{status: :read, request_ids: Enum.map(items, & &1.id), read_at: now}})
    )
  end
end

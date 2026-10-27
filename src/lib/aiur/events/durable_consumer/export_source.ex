defmodule Aiur.Events.DurableConsumer.ExportSource do
  @moduledoc """
  Export journal source. Pass `cursor_path` matching the consumer's cursor file.

  Append notifications invalidate the consumer's view; catch-up performs bounded
  reads and handles epoch changes even when new sequence numbers overlap the old
  cursor. A periodic invalidation also recovers a lost final notification.
  """
  # Consumer adapter: intentionally outside the dependency-free bus boundary.
  use GenServer
  @behaviour Aiur.Events.DurableConsumer.Source
  alias Aiur.Events.Export
  alias Aiur.JsonStore

  @impl Aiur.Events.DurableConsumer.Source
  def subscribe(opts, consumer) do
    {:ok, relay} = GenServer.start_link(__MODULE__, {opts, consumer})
    Process.put({__MODULE__, opts}, relay)
    :ok
  end

  @impl Aiur.Events.DurableConsumer.Source
  def replay(opts, cursor, limit) do
    GenServer.call(Process.get({__MODULE__, opts}), {:replay, cursor, min(limit, 500)})
  end

  @impl Aiur.Events.DurableConsumer.Source
  def position(record), do: Map.fetch!(record, "seq")

  @impl GenServer
  def init({opts, consumer}) do
    :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, "events:export")
    Process.monitor(consumer)
    path = Keyword.fetch!(opts, :cursor_path) <> ".epoch"

    epoch =
      case JsonStore.read(path) do
        {:ok, %{"epoch" => epoch}} when is_binary(epoch) -> epoch
        _ -> nil
      end

    state = %{consumer: consumer, path: path, epoch: epoch, pending: nil, retry_ms: Keyword.get(opts, :retry_ms, 5_000)}
    schedule(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:replay, cursor, limit}, _, state) do
    # The consumer has persisted the reset cursor before making its next read.
    state = commit_pending(state, cursor)
    opts = if is_nil(state.epoch) and cursor == 0, do: [], else: [epoch: state.epoch]

    case Export.read(cursor, limit, ["#"], opts) do
      {:ok, %{records: records, epoch: epoch}} ->
        if state.epoch != epoch, do: JsonStore.write!(state.path, %{"epoch" => epoch})
        {:reply, {:ok, records}, %{state | epoch: epoch}}

      {:reset, %{oldest_seq: oldest, epoch: epoch}} ->
        {:reply, {:reset, oldest}, %{state | pending: {epoch, max(oldest - 1, 0)}}}

      {:error, :events_unavailable} = error ->
        {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_info({:export_appended, _head, _epoch}, state) do
    send(state.consumer, :catch_up)
    {:noreply, state}
  end

  def handle_info(:retry, state) do
    send(state.consumer, :catch_up)
    schedule(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _, :process, consumer, _}, %{consumer: consumer} = state), do: {:stop, :normal, state}

  defp commit_pending(%{pending: {epoch, cursor}} = state, cursor) do
    JsonStore.write!(state.path, %{"epoch" => epoch})
    %{state | epoch: epoch, pending: nil}
  end

  defp commit_pending(state, _cursor), do: state
  defp schedule(state), do: Process.send_after(self(), :retry, state.retry_ms)
end

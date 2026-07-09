defmodule Aiur.PaneManager.OpenQueue do
  @moduledoc """
  Pure queue and timer-map transforms for PaneManager open requests.
  """

  # How long a queued open will wait for a slot to become `:ready` before
  # we reply `{:error, :no_ready_slot}` to the caller. Generous because
  # chain pre-warm sets the lower bound (slot N takes ~5 s after N-1
  # broadcasts ready); a stalled chain still completes within this window
  # in any realistic configuration.
  @open_queue_timeout_ms 60_000

  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: @open_queue_timeout_ms

  @spec queued?(%{optional(String.t()) => reference()}, String.t()) :: boolean()
  def queued?(timers, identifier), do: Map.has_key?(timers, identifier)

  @spec enqueue(:queue.queue(), map(), String.t(), GenServer.from(), reference()) ::
          {:queue.queue(), map()}
  def enqueue(queue, timers, identifier, from, timer_ref) do
    {:queue.in({identifier, from, timer_ref}, queue), Map.put(timers, identifier, timer_ref)}
  end

  @spec pop(:queue.queue()) :: :empty | {tuple(), :queue.queue()}
  def pop(queue) do
    case :queue.out(queue) do
      {:empty, _} -> :empty
      {{:value, entry}, rest} -> {entry, rest}
    end
  end

  @spec pluck(:queue.queue(), map(), String.t()) ::
          :not_queued | {GenServer.from(), :queue.queue(), map()}
  def pluck(queue, timers, identifier) do
    case Map.fetch(timers, identifier) do
      :error ->
        # Already drained — timer fired after the entry was dequeued
        # but before the timer could be cancelled cleanly. No-op.
        :not_queued

      {:ok, _timer_ref} ->
        # Walk the queue once to find this identifier and pluck it.
        {entries, dropped_from} =
          queue
          |> :queue.to_list()
          |> Enum.reduce({[], nil}, fn
            {^identifier, from, _ref}, {acc, nil} -> {acc, from}
            other, {acc, dropped} -> {[other | acc], dropped}
          end)

        case dropped_from do
          nil ->
            :not_queued

          from ->
            {from, :queue.from_list(Enum.reverse(entries)), Map.delete(timers, identifier)}
        end
    end
  end
end

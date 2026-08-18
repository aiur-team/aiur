defmodule Aiur.DecisionDispatchTasks.Queue do
  @moduledoc false

  @type state :: map()
  @type ticket :: Aiur.DecisionDispatchTasks.ticket()

  @spec admit?(state(), ticket()) :: boolean()
  def admit?(state, ticket) do
    state.pending < state.max_pending and
      pending_for_ticket(state, ticket) < state.max_pending_per_ticket
  end

  @spec put(state(), ticket(), map()) :: state()
  def put(state, ticket, entry) do
    queue = Map.get(state.queues, ticket, :queue.new())

    state
    |> Map.put(:queues, Map.put(state.queues, ticket, :queue.in(entry, queue)))
    |> Map.update!(:pending, &(&1 + 1))
    |> make_runnable(ticket)
  end

  @spec pop(state()) :: {ticket(), map(), state()} | :empty
  def pop(state) do
    case :queue.out(state.runnable_tickets) do
      {{:value, ticket}, runnable_tickets} ->
        state = %{
          state
          | runnable_tickets: runnable_tickets,
            runnable_ticket_set: MapSet.delete(state.runnable_ticket_set, ticket)
        }

        if runnable?(state, ticket), do: pop_entry(state, ticket), else: pop(state)

      {:empty, _queue} ->
        :empty
    end
  end

  @spec make_runnable(state(), ticket()) :: state()
  def make_runnable(state, ticket) do
    if runnable?(state, ticket) and not MapSet.member?(state.runnable_ticket_set, ticket) do
      %{
        state
        | runnable_tickets: :queue.in(ticket, state.runnable_tickets),
          runnable_ticket_set: MapSet.put(state.runnable_ticket_set, ticket)
      }
    else
      state
    end
  end

  @spec owner_present?(state(), pid()) :: boolean()
  def owner_present?(state, owner) do
    Enum.any?(state.active, fn {_ticket, task} -> task.owner == owner end) or
      Enum.any?(state.queues, fn {_ticket, queue} ->
        Enum.any?(:queue.to_list(queue), &(&1.owner == owner))
      end)
  end

  @spec drop_owner(state(), pid()) :: {state(), MapSet.t(ticket())}
  def drop_owner(state, owner) do
    {queues, removed, tickets} =
      Enum.reduce(state.queues, {%{}, 0, MapSet.new()}, fn {ticket, queue}, {queues, removed, tickets} ->
        entries = :queue.to_list(queue)
        retained = Enum.reject(entries, &(&1.owner == owner))
        removed_here = length(entries) - length(retained)

        queues =
          if retained == [],
            do: queues,
            else: Map.put(queues, ticket, :queue.from_list(retained))

        tickets = if removed_here > 0, do: MapSet.put(tickets, ticket), else: tickets
        {queues, removed + removed_here, tickets}
      end)

    {%{state | queues: queues, pending: state.pending - removed}, tickets}
  end

  defp pop_entry(state, ticket) do
    queue = Map.fetch!(state.queues, ticket)
    {{:value, entry}, remaining} = :queue.out(queue)

    queues =
      if :queue.is_empty(remaining),
        do: Map.delete(state.queues, ticket),
        else: Map.put(state.queues, ticket, remaining)

    {ticket, entry, %{state | queues: queues, pending: state.pending - 1}}
  end

  defp runnable?(state, ticket) do
    not Map.has_key?(state.active, ticket) and
      case Map.fetch(state.queues, ticket) do
        {:ok, queue} -> not :queue.is_empty(queue)
        :error -> false
      end
  end

  defp pending_for_ticket(state, ticket) do
    state.queues
    |> Map.get(ticket, :queue.new())
    |> :queue.len()
  end
end

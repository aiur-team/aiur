defmodule Aiur.DecisionDispatchTasks.Owner do
  @moduledoc false

  alias Aiur.DecisionDispatchTasks.{Queue, Saturation, Worker}

  @type state :: map()

  @spec monitor(state(), pid()) :: state()
  def monitor(state, owner) do
    if Map.has_key?(state.owner_monitors, owner) do
      state
    else
      %{state | owner_monitors: Map.put(state.owner_monitors, owner, Process.monitor(owner))}
    end
  end

  @spec cleanup(state(), pid()) :: state()
  def cleanup(state, owner) do
    if Queue.owner_present?(state, owner) do
      state
    else
      {ref, owner_monitors} = Map.pop(state.owner_monitors, owner)
      if is_reference(ref), do: Process.demonitor(ref, [:flush])
      %{state | owner_monitors: owner_monitors}
    end
  end

  @spec by_ref(%{optional(pid()) => reference()}, reference()) :: pid() | nil
  def by_ref(owner_monitors, ref) do
    Enum.find_value(owner_monitors, fn {owner, owner_ref} ->
      if owner_ref == ref, do: owner
    end)
  end

  @spec purge(state(), pid()) :: state()
  def purge(state, owner) do
    {state, active_tickets} = purge_tasks(state, owner)
    {state, queued_tickets} = Queue.drop_owner(state, owner)
    state = %{state | owner_monitors: Map.delete(state.owner_monitors, owner)}

    active_tickets
    |> MapSet.union(queued_tickets)
    |> Enum.reduce(state, &Queue.make_runnable(&2, &1))
    |> Saturation.maybe_resolve()
  end

  defp purge_tasks(state, owner) do
    Enum.reduce(state.active, {state, MapSet.new()}, fn {ticket, task}, {state, tickets} ->
      if task.owner == owner do
        Process.demonitor(task.ref, [:flush])
        Worker.cancel_timeout(task.timer, task.ref)
        _ = Worker.terminate(task)

        {%{state | active: Map.delete(state.active, ticket)}, MapSet.put(tickets, ticket)}
      else
        {state, tickets}
      end
    end)
  end
end

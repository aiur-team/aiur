defmodule Aiur.GitHub.ViewStateDemand do
  @moduledoc """
  Demand tracking shared by the view-state sources that
  `Aiur.GitHub.ViewStateSweep` reconciles.

  A view-state source is refreshed only while at least one LiveView session is
  watching it. A watching session is a **demander**: the source's `subscribe/0`
  registers the calling LiveView process, and a monitor releases it when that
  process dies. Closing the last tab therefore empties the set and stops the
  refresh without an explicit unsubscribe and without a leaked count.

  Each source embeds two keys in its GenServer state — `demanders` (a `MapSet`
  of pids) and `demand_monitors` (`%{monitor_ref => pid}`) — and delegates to
  the functions here, so the bookkeeping is one implementation rather than
  three copies.
  """

  @type t :: %{
          demanders: MapSet.t(pid()),
          demand_monitors: %{reference() => pid()}
        }

  @doc """
  Registers `pid` as a demander.

  Answers `{state, first?}` where `first?` is true exactly when this is the
  first demander — the signal a source uses for "one refresh on mount".
  Re-registering a pid that already holds demand is a no-op and never answers
  `first?`, so one LiveView session re-calling subscribe does not double-count
  or double-fetch.
  """
  @spec demand(t(), pid()) :: {t(), boolean()}
  def demand(%{demanders: demanders} = state, pid) when is_pid(pid) do
    if MapSet.member?(demanders, pid) do
      {state, false}
    else
      first? = MapSet.size(demanders) == 0
      ref = Process.monitor(pid)

      {%{
         state
         | demanders: MapSet.put(demanders, pid),
           demand_monitors: Map.put(state.demand_monitors, ref, pid)
       }, first?}
    end
  end

  @doc """
  Releases `pid`'s demand and demonitors it.

  The counterpart to `demand/2` for callers that release demand explicitly.
  Sessions that do not call it are still released by the monitor on death.
  """
  @spec undemand(t(), pid()) :: t()
  def undemand(%{demanders: demanders, demand_monitors: monitors} = state, pid) when is_pid(pid) do
    case Enum.find(monitors, fn {_ref, demander} -> demander == pid end) do
      {ref, ^pid} ->
        Process.demonitor(ref, [:flush])

        %{
          state
          | demanders: MapSet.delete(demanders, pid),
            demand_monitors: Map.delete(monitors, ref)
        }

      nil ->
        state
    end
  end

  @doc """
  Handles a `:DOWN` message for a demander monitor, removing that demander.

  A `:DOWN` whose reference is not a demander monitor is returned untouched, so
  a source can funnel every `:DOWN` through here and let the caller's other
  `:DOWN` clauses (task exits, etc.) match first.
  """
  @spec handle_down(t(), reference()) :: t()
  def handle_down(%{demand_monitors: monitors} = state, ref) do
    case Map.pop(monitors, ref) do
      {nil, _monitors} ->
        state

      {pid, monitors} ->
        %{state | demanders: MapSet.delete(state.demanders, pid), demand_monitors: monitors}
    end
  end

  @doc "Whether any LiveView session is currently watching the source."
  @spec demanded?(t()) :: boolean()
  def demanded?(%{demanders: demanders}), do: MapSet.size(demanders) > 0

  @doc "The number of LiveView sessions currently watching the source."
  @spec count(t()) :: non_neg_integer()
  def count(%{demanders: demanders}), do: MapSet.size(demanders)
end

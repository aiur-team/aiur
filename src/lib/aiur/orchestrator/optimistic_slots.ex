defmodule Aiur.Orchestrator.OptimisticSlots do
  @moduledoc "Fleet-wide optimistic share; occupied runners are reclassified against current cached evidence."

  alias Aiur.{Config, Issue}
  alias Aiur.Orchestrator.{DependencyGate, DispatchPolicy, Slots, State}

  @spec status(State.t()) :: %{running: non_neg_integer(), cap: non_neg_integer(), share: float()}
  def status(state) do
    share = Config.settings!().build_queue.optimistic_slot_share
    cap = if share == 0, do: 0, else: max(1, floor(share * Slots.effective_concurrent_agent_limit(state)))
    terminal = DispatchPolicy.terminal_state_set()

    running =
      Enum.count(state.running, fn {id, entry} ->
        occupied?(entry) and optimistic?(Map.get(state.last_polled_issues, id), entry, terminal)
      end)

    %{running: running, cap: cap, share: share}
  end

  @spec available?(Issue.t(), State.t(), MapSet.t()) :: boolean()
  def available?(issue, state, terminal) do
    if DependencyGate.classify(issue, terminal) == :optimistic do
      %{running: running, cap: cap} = status(state)
      running < cap
    else
      true
    end
  end

  @spec start_mode([String.t()]) :: :ready | :optimistic
  def start_mode([]), do: :ready
  def start_mode(_blockers), do: :optimistic

  @spec label(map()) :: String.t()
  def label(%{optimistic: %{running: running, cap: cap}}), do: "; optimistic #{running}/#{cap}"
  def label(_capacity), do: ""

  @spec waiting(State.t()) :: String.t()
  def waiting(state) do
    %{running: running, cap: cap} = status(state)
    "waiting: optimistic share full (#{running}/#{cap})"
  end

  defp occupied?(entry), do: State.active_running_entry?(entry) or State.reserved_paused_running_count(%{entry: entry}) > 0

  defp optimistic?(%Issue{} = issue, entry, terminal) do
    issue = DependencyGate.cached_issue(issue, Map.get(entry, :issue))
    issue = if is_nil(issue.blocked_by), do: Map.get(entry, :issue, issue), else: issue

    case DependencyGate.classify(issue, terminal) do
      :ready -> false
      :optimistic -> true
      :held -> Map.get(entry, :start_mode) == :optimistic or Map.get(entry, :optimistic_blockers, []) != []
    end
  end

  defp optimistic?(_missing, entry, _terminal), do: Map.get(entry, :start_mode) == :optimistic or Map.get(entry, :optimistic_blockers, []) != []
end

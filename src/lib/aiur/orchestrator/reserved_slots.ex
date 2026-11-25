defmodule Aiur.Orchestrator.ReservedSlots do
  @moduledoc """
  Slots held for tickets carrying a configured label (`agent.reserved_slots`).

  A label's reserve is outstanding while a ticket carrying it is dispatchable,
  or backing off before a retry, and fewer than its count of agents with the
  label hold a slot. Every other ticket leaves the outstanding slots free, so
  the labelled ticket takes the next slot that opens.
  """

  alias Aiur.{Config, Issue}
  alias Aiur.Orchestrator.{DispatchPolicy, State}

  @doc "Slots `issue` must leave free for labels it does not carry."
  @spec held_for_others(Issue.t(), State.t()) :: non_neg_integer()
  def held_for_others(%Issue{} = issue, %State{} = state) do
    issue |> holds(state) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
  end

  @doc "Why `issue` waits, naming each label holding a slot it cannot take; nil when none does."
  @spec waiting(Issue.t(), State.t()) :: String.t() | nil
  def waiting(%Issue{} = issue, %State{} = state) do
    case holds(issue, state) do
      [] -> nil
      holds -> "reserved_slot: " <> Enum.map_join(holds, ", ", fn {label, n} -> "#{n} held for #{label}" end)
    end
  end

  @doc "The status text for a ticket last declined as `:reserved_slot`; the generic text when no reserve holds it now."
  @spec waiting_text(term(), State.t()) :: String.t()
  def waiting_text(%Issue{} = issue, %State{} = state), do: waiting(issue, state) || generic()
  def waiting_text(_issue, _state), do: generic()

  defp generic, do: "reserved_slot: waiting for a slot held for a labelled ticket"

  defp holds(issue, state) do
    own = labels(issue)

    for {label, count} <- Enum.sort(Config.settings!().agent.reserved_slots),
        not MapSet.member?(own, label),
        held = outstanding(label, count, state),
        held > 0,
        do: {label, held}
  end

  defp outstanding(label, count, state) do
    occupants = Map.filter(state.running, fn {_id, entry} -> carries?(Map.get(entry, :issue), label) end)
    free = count - State.active_running_count(occupants) - State.reserved_paused_running_count(occupants)
    if free > 0, do: min(free, waiting_count(label, state, occupants)), else: 0
  end

  defp waiting_count(label, state, occupants) do
    Enum.count(Map.values(state.last_polled_issues), fn issue ->
      carries?(issue, label) and not Map.has_key?(occupants, issue.id) and
        DispatchPolicy.dispatch_candidate_decision(issue, state) in [:dispatch, {:skip, :retry_backoff}]
    end)
  end

  defp carries?(%Issue{} = issue, label), do: MapSet.member?(labels(issue), label)
  defp carries?(_issue, _label), do: false

  defp labels(%Issue{labels: labels}) when is_list(labels), do: MapSet.new(labels, &String.downcase/1)
  defp labels(_issue), do: MapSet.new()
end

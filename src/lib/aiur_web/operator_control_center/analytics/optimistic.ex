defmodule AiurWeb.OperatorControlCenter.Analytics.Optimistic do
  @moduledoc "Summarizes observed optimistic starts without treating missing outcomes as zero head start."

  @spec summary(map()) :: map()
  def summary(tickets) do
    started =
      tickets
      |> Enum.map(fn {_id, ticket} -> Map.get(ticket, :events, []) end)
      |> Enum.filter(&Enum.any?(&1, fn event -> event.event == "optimistic_start" end))

    outcomes = Enum.map(started, &Enum.find(Enum.reverse(&1), fn event -> event.event == "optimistic_outcome" end))
    merged = Enum.filter(outcomes, &(outcome(&1) in ["merged", "merged_after_redo"]))
    head_starts = Enum.map(merged, &Map.get(&1, :head_start_ms))

    %{
      starts: length(started),
      redone: Enum.count(outcomes, &(outcome(&1) == "merged_after_redo")),
      discarded: Enum.count(outcomes, &(outcome(&1) == "discarded")),
      head_start_ms: if(head_starts != [] and Enum.all?(head_starts, &(is_integer(&1) and &1 >= 0)), do: Enum.sum(head_starts))
    }
  end

  defp outcome(nil), do: nil
  defp outcome(event), do: Map.get(event, :outcome)
end

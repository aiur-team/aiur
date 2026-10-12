defmodule AiurWeb.OperatorControlCenter.Analytics.TicketRow do
  @moduledoc "Projects ticket lifecycle milestones and status onto the analytics timeline."

  @spec build(String.t(), map(), (integer() -> integer())) :: map() | nil
  def build(id, ticket, project) do
    intervals = Map.get(ticket, :intervals, [])
    starts = intervals |> Enum.map(&Map.get(&1, :start_ms)) |> Enum.filter(&is_integer/1)

    if starts == [] do
      nil
    else
      ends = intervals |> Enum.map(fn iv -> Map.get(iv, :end_ms) || Map.get(iv, :start_ms) end) |> Enum.filter(&is_integer/1)
      start_ms = Enum.min(starts)
      work_ms = phase_start(intervals, ["implement", "agent_spinup", "build_test"]) || start_ms
      pr_opened_at = phase_start(intervals, ["pr_opened"])
      merged_at = phase_start(intervals, ["pr_merged"])
      end_ms = merged_at || Enum.max([start_ms | ends])

      %{
        id: id,
        start_ms: project.(start_ms),
        work_ms: project.(work_ms),
        end_ms: project.(end_ms),
        pr_opened_at: pr_opened_at && project.(pr_opened_at),
        merged_at: merged_at && project.(merged_at),
        status: ticket_status(intervals, merged_at)
      }
    end
  end

  defp ticket_status(intervals, merged_at) do
    phases = intervals |> Enum.map(&Map.get(&1, :phase)) |> MapSet.new()

    cond do
      merged_at -> :merged
      MapSet.member?(phases, "rework_start") -> :rework
      MapSet.member?(phases, "agent_pause") -> :paused
      MapSet.member?(phases, "pr_opened") -> :in_review
      true -> :active
    end
  end

  defp phase_start(intervals, phases) do
    intervals
    |> Enum.filter(&(Map.get(&1, :phase) in phases and is_integer(Map.get(&1, :start_ms))))
    |> Enum.map(&Map.get(&1, :start_ms))
    |> case do
      [] -> nil
      list -> Enum.min(list)
    end
  end
end

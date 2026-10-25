defmodule Aiur.MainWatch.Canary do
  @moduledoc "Pure stale-run canary decision; the server owns the once-per-window latch."

  @spec decide(integer(), [map()], non_neg_integer(), boolean(), integer(), String.t() | nil) :: :noop | {:rerun, integer()} | {:attention, atom()}
  def decide(last_completed_at, runs, minutes, actions_write, now_ms, newest_sha \\ nil) do
    cond do
      minutes == 0 or now_ms - last_completed_at < minutes * 60_000 -> :noop
      Enum.any?(runs, &(&1.status != "completed")) -> :noop
      completed_latest?(runs, newest_sha) -> :noop
      true -> cancelled_run(runs, actions_write, newest_sha)
    end
  end

  defp completed_latest?(_runs, nil), do: false

  defp completed_latest?(runs, newest_sha),
    do: Enum.any?(runs, &(Map.get(&1, :sha) == newest_sha and &1.status == "completed" and &1.conclusion != "cancelled"))

  defp cancelled_run(runs, actions_write, newest_sha) do
    case Enum.find(runs, &(&1.status == "completed" and &1.conclusion == "cancelled" and (is_nil(newest_sha) or Map.get(&1, :sha) == newest_sha))) do
      nil -> :noop
      _run when not actions_write -> {:attention, :actions_write_unavailable}
      run -> {:rerun, run.id}
    end
  end
end

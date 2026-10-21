defmodule Aiur.AgentControlCLIFreshness do
  @moduledoc false

  alias Aiur.Orchestrator.StatusObservation
  alias AiurWeb.OperatorControlCenter.UnitsPresentation

  @spec print(map(), map() | nil) :: :ok
  def print(%{status: :stale} = freshness, global_pause) do
    IO.puts(
      "STALE FLEET VIEW — showing the last-known-good snapshot, #{UnitsPresentation.age_label(Map.get(freshness, :age_seconds))} old" <>
        stale_reason(Map.get(freshness, :reason), global_pause)
    )
  end

  def print(freshness, _global_pause), do: IO.puts("FLEET SNAPSHOT " <> StatusObservation.label(freshness))

  defp stale_reason(:snapshot_timeout, _global_pause), do: " (the snapshot projection timed out)"

  defp stale_reason(:snapshot_stalled, %{globally_paused: true, paused_at: %DateTime{} = paused_at}),
    do: " (global pause active since #{DateTime.to_iso8601(paused_at)})"

  defp stale_reason(:snapshot_stalled, _global_pause), do: " (the orchestrator has stopped publishing)"
  defp stale_reason(:orchestrator_unavailable, _global_pause), do: " (the orchestrator is unavailable)"
  defp stale_reason(_reason, _global_pause), do: ""
end

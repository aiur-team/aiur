defmodule Aiur.Orchestrator.PauseResume.Clocks do
  @moduledoc """
  Resets a resumed worker's activity and duration clocks.
  """

  @doc false
  @spec reset_last_codex_timestamp(map(), term(), DateTime.t()) :: map()
  def reset_last_codex_timestamp(running, issue_id, %DateTime{} = now) when is_map(running) do
    case Map.get(running, issue_id) do
      entry when is_map(entry) ->
        Map.put(running, issue_id, Map.put(entry, :last_codex_timestamp, now))

      _ ->
        running
    end
  end

  # Resume-side handling for a duration-capped pause. Only this control path
  # owns the `:max_agent_duration` marker; other pause/wait reasons must stay
  # intact until the subsystem that created them clears them.
  #
  # `operator?: true` ALSO restarts the duration baseline (`started_at` ->
  # now) so an Executor resume hands the agent a full fresh budget.
  #
  # `operator?: false` PRESERVES `started_at` (the cumulative overrun) so an
  # automated/blocker auto-resume cannot silently reset the budget: the
  # entry resumes already over the cap and the next overrun tick re-pauses
  # it, which is the runaway safety net — a wedged duration-capped agent
  # that keeps getting auto-resumed on blocker unblocked signals stays bounded
  # instead of running forever.
  #
  # Label-override pauses have no special duration semantics; resuming just
  # clears their attribution marker after the normal pause-clock thaw.
  #
  # A no-op for manually/blocker-paused entries (no marker).
  @doc false
  @spec reset_duration_clock_if_capped(map(), term(), DateTime.t(), boolean()) :: map()
  def reset_duration_clock_if_capped(running, issue_id, %DateTime{} = now, operator?)
      when is_map(running) do
    case Map.get(running, issue_id) do
      %{paused_reason: :max_agent_duration} = entry ->
        updated =
          entry
          |> maybe_reset_started_at(now, operator?)
          |> Map.delete(:paused_reason)

        Map.put(running, issue_id, updated)

      _ ->
        running
    end
  end

  defp maybe_reset_started_at(entry, now, true), do: Map.put(entry, :started_at, now)
  defp maybe_reset_started_at(entry, _now, false), do: entry
end

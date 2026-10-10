defmodule Aiur.BuildQueue.Refresh do
  @moduledoc """
  Requests the queue's own open-issue listing when the shared snapshot has gone stale.

  The dispatch poll normally renews that snapshot. When its cycle stalls, a
  non-empty queue asks the tracker for a listing-only refresh from a separate
  process, at most once per observation age. The listing selects no dispatch
  candidates. It needs the daemon scheduled and the tracker reachable, so it
  shortens a stall rather than guaranteeing freshness.
  """
  require Logger

  alias Aiur.BuildQueue.Settings

  @spec maybe_request(map()) :: map()
  def maybe_request(%{document: %{items: [_ | _]}} = state) do
    now = state.clock.()
    max_age = Settings.observation_max_age_ms(state.settings)
    tracker = state.tracker

    cond do
      # The dispatch poll gets one observation age after boot before the queue lists for itself.
      is_nil(state.refresh_not_before_ms) ->
        %{state | refresh_not_before_ms: now + max_age}

      now >= state.refresh_not_before_ms and stale?(tracker, now, max_age) and Code.ensure_loaded?(tracker) and function_exported?(tracker, :refresh_open_issue_labels, 0) ->
        Logger.info("build_queue_refresh requested: open-issue observation is older than #{max_age}ms")
        {:ok, _pid} = Task.start(fn -> tracker.refresh_open_issue_labels() end)
        %{state | refresh_not_before_ms: now + max_age}

      true ->
        state
    end
  end

  def maybe_request(state), do: state

  defp stale?(tracker, now, max_age) do
    case tracker.open_issue_labels(max_age) do
      {:ok, _labels, observed_at} when observed_at <= now and now - observed_at <= max_age -> false
      _ -> true
    end
  end
end

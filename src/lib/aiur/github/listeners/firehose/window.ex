defmodule Aiur.GitHub.Listeners.Firehose.Window do
  @moduledoc false
  require Logger
  alias Aiur.{AlertFeed, Alerts, RunTelemetry}
  alias Aiur.Events.GithubFirehose
  alias Aiur.GitHub.Listeners.Firehose

  @firehose_truncation_threshold 2

  # The firehose window metric (#2354). Every successful tick records how many
  # event pages were fetched and whether the previous watermark was reachable
  # inside GitHub's events window. `partial?` is true only when the poll hit
  # `@events_window_pages` without finding the watermark — events beyond the
  # window were genuinely lost, not merely skipped — and is the signal the
  # sustained-truncation attention keys on.
  @spec note_firehose_window(Firehose.t(), map(), keyword()) :: Firehose.t()
  def note_firehose_window(state, result, opts) do
    partial? = Map.get(result, :partial_window?, false)
    pages_fetched = Map.get(result, :pages_fetched, 0)
    published = Map.get(result, :count, 0)

    Logger.info("aiur_perf github_firehose pages=#{pages_fetched} capped=#{partial?} published=#{published}")

    telemetry_fun = Keyword.get(opts, :firehose_poll_telemetry_fun, &RunTelemetry.record/2)

    _ =
      telemetry_fun.(:firehose_poll, %{
        pages_fetched: pages_fetched,
        partial_window?: partial?,
        published: published
      })

    streak = if partial?, do: state.firehose_partial_streak + 1, else: 0
    state = %{state | firehose_partial_streak: streak}
    reconcile_firehose_truncation_alert(state, partial?, streak, opts)
  end

  # Fires the attention once a truncated window becomes the steady state, and
  # resolves it the first tick the window is complete again. Mirrors the
  # dispatcher's prewarm-blocked alert lifecycle.
  #
  # The resolve decision reads both the in-memory latch and the durable alert
  # feed: after an Orchestrator restart the in-memory flag is lost while the
  # feed still carries the attention, so a complete window must still clear it.
  defp reconcile_firehose_truncation_alert(%Firehose{} = state, false, _streak, opts) do
    resolve? =
      state.firehose_truncation_alert_active or
        AlertFeed.active_system_attention?("system.firehose.event_truncation")

    if resolve?, do: resolve_firehose_truncation_alert(state, opts), else: state
  end

  defp reconcile_firehose_truncation_alert(state, true, streak, opts) when streak >= @firehose_truncation_threshold,
    do: arm_firehose_truncation_alert(state, opts)

  defp reconcile_firehose_truncation_alert(state, _partial?, _streak, _opts), do: state

  defp arm_firehose_truncation_alert(%Firehose{firehose_truncation_alert_active: true} = state, _opts), do: state

  defp arm_firehose_truncation_alert(%Firehose{} = state, opts) do
    reason =
      "The GitHub repo-events firehose hit its #{GithubFirehose.events_window_pages()} page bound on " <>
        "#{state.firehose_partial_streak} consecutive ticks without reaching the previous event watermark. " <>
        "Events beyond GitHub's #{GithubFirehose.events_window_pages() * GithubFirehose.repo_events_per_page()}-event " <>
        "window are being dropped each tick; the firehose is truncating an unbounded stream."

    case firehose_truncation_alert_fun(opts).("system.firehose.event_truncation",
           reason: reason,
           needs_attention: true,
           severity: "warning"
         ) do
      :ok -> %{state | firehose_truncation_alert_active: true, firehose_truncation_alert_resolution_emitted: false}
      {:error, _reason} -> state
    end
  end

  defp resolve_firehose_truncation_alert(%Firehose{firehose_truncation_alert_resolution_emitted: true} = state, _opts),
    do: %{state | firehose_truncation_alert_active: false}

  defp resolve_firehose_truncation_alert(%Firehose{} = state, opts) do
    _ =
      firehose_truncation_alert_fun(opts).("system.firehose.event_truncation.resolved",
        reason: "The GitHub repo-events firehose returned a complete event window; the truncation attention clears.",
        needs_attention: false,
        severity: "info"
      )

    %{state | firehose_truncation_alert_active: false, firehose_truncation_alert_resolution_emitted: true}
  end

  defp firehose_truncation_alert_fun(opts) do
    Keyword.get(opts, :firehose_truncation_alert_fun, &Alerts.emit_system/2)
  end
end

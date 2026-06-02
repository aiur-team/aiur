defmodule Aiur.ProgressTracker do
  @moduledoc """
  Pure helpers + ETS-backed sample store for the agent-list progress
  column (R2). Agents publish `ticket.<id>.agent.progress` events with
  `%{percent: 0..100, label: optional}` whenever they want to update
  their estimate. This module keeps a small ring of recent samples per
  identifier and projects an ETA from them — entirely on the
  orchestrator/renderer side, never on the agent side.

  Public functions:

    * `record/3` — append a sample for an identifier.
    * `estimate/2` — compute `%{percent, eta_seconds}` for an identifier
      at a given `now_ms`. Returns `:unknown` for no samples; an integer
      percent + `:unknown` ETA for a single sample; both fields filled
      from the most recent two samples when available.
    * `bar/2` — ASCII progress bar string of width `n` for a 0..100
      percent. Block character + filler.

  Sample shape is intentionally a tiny tuple so test fixtures stay
  readable: `{percent, monotonic_ms}`. The store keeps at most
  `@max_samples` per identifier so a chatty agent can't grow memory
  without bound.
  """

  @max_samples 8

  # Samples older than this contribute neither to current percent
  # nor ETA — agent has gone silent, the projection is stale.
  @stale_after_ms 300_000

  @doc """
  Append a sample for `identifier`. `percent` clamped to 0..100;
  `now_ms` is a monotonic millisecond timestamp (test injection).
  Returns the new list of samples (newest first).
  """
  @spec record([{integer(), integer()}], integer(), integer()) :: [{integer(), integer()}]
  def record(samples, percent, now_ms) when is_list(samples) do
    clamped = clamp_percent(percent)
    [{clamped, now_ms} | samples] |> Enum.take(@max_samples)
  end

  @doc """
  Compute the projected `%{percent, eta_seconds}` for an identifier.

  * No samples → `:unknown`.
  * Stale samples (oldest within window older than `@stale_after_ms`)
    → percent is the last sample value, `eta_seconds: :unknown`.
  * Single recent sample → percent is that sample, no ETA yet.
  * Two or more recent samples → linear extrapolation from the
    most recent pair. ETA is the remaining seconds to 100% at the
    derived rate; capped at 24h so a near-zero rate doesn't
    project absurd durations.

  `now_ms` lets the renderer tick ETA down between samples.
  """
  @spec estimate([{integer(), integer()}], integer()) ::
          :unknown | %{percent: integer(), eta_seconds: non_neg_integer() | :unknown}
  def estimate([], _now_ms), do: :unknown

  def estimate(samples, now_ms) do
    {latest_percent, latest_at} = hd(samples)

    if now_ms - latest_at > @stale_after_ms do
      %{percent: latest_percent, eta_seconds: :unknown}
    else
      eta = compute_eta(samples, now_ms, latest_percent, latest_at)
      %{percent: project_percent(samples, now_ms, latest_percent, latest_at), eta_seconds: eta}
    end
  end

  @doc """
  Render a fixed-width ASCII progress bar for `percent`. `width` is
  total visible columns; the bar uses `█` (full) and `░` (empty).
  `percent` clamped to 0..100.
  """
  @spec bar(integer(), pos_integer()) :: String.t()
  def bar(percent, width) when is_integer(percent) and is_integer(width) and width > 0 do
    pct = clamp_percent(percent)
    filled = trunc(pct * width / 100)
    String.duplicate("█", filled) <> String.duplicate("░", width - filled)
  end

  def bar(_percent, _width), do: ""

  @doc """
  Format an `eta_seconds` value as a short human-readable string.
  Returns `""` for `:unknown` so the column reads as empty space
  rather than a placeholder glyph. For concrete durations: compact
  `MM:SS` or `Hh MMm` depending on magnitude.
  """
  @spec format_eta(non_neg_integer() | :unknown) :: String.t()
  def format_eta(:unknown), do: ""

  def format_eta(s) when is_integer(s) and s >= 3600 do
    h = div(s, 3600)
    m = div(rem(s, 3600), 60)
    "#{h}h #{m}m"
  end

  def format_eta(s) when is_integer(s) and s >= 0 do
    m = div(s, 60)
    sec = rem(s, 60)
    "#{m}:#{String.pad_leading(Integer.to_string(sec), 2, "0")}"
  end

  def format_eta(_), do: ""

  defp clamp_percent(p) when is_integer(p), do: min(max(p, 0), 100)
  defp clamp_percent(p) when is_float(p), do: clamp_percent(trunc(p))
  defp clamp_percent(_), do: 0

  # Project the current percent based on the derived rate so the
  # bar appears to advance smoothly between explicit samples,
  # without ever crossing 99 (so we don't false-promise completion).
  defp project_percent([_], _now_ms, latest_percent, _latest_at), do: latest_percent

  defp project_percent([{latest_p, latest_at} | [{prev_p, prev_at} | _]], now_ms, _, _) do
    dt = latest_at - prev_at

    if dt <= 0 do
      latest_p
    else
      rate = (latest_p - prev_p) / dt
      elapsed_since = now_ms - latest_at
      projected = latest_p + rate * elapsed_since
      projected |> trunc() |> min(99) |> max(0)
    end
  end

  defp compute_eta([_], _now_ms, _latest_percent, _latest_at), do: :unknown

  defp compute_eta([{latest_p, latest_at} | [{prev_p, prev_at} | _]], now_ms, _, _) do
    dt = latest_at - prev_at

    cond do
      dt <= 0 ->
        :unknown

      latest_p - prev_p <= 0 ->
        :unknown

      true ->
        rate_per_ms = (latest_p - prev_p) / dt
        remaining_pct = 100 - latest_p
        elapsed_since = now_ms - latest_at
        ms_to_done = remaining_pct / rate_per_ms - elapsed_since
        ms_to_done |> trunc() |> div(1000) |> max(0) |> min(86_400)
    end
  end
end

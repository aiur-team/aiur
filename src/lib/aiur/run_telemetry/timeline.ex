defmodule Aiur.RunTelemetry.Timeline do
  @moduledoc """
  Projects wall-clock telemetry timestamps onto a chart axis.

  Two projections exist. `identity/0` passes absolute milliseconds straight
  through and is what the live-session view uses — one session is contiguous, so
  wall clock and elapsed time agree.

  `active/2` is for scopes that span many sessions. A Build Order runs over weeks
  of wall clock but only hours of actual activity, and the idle stretches between
  sessions are not interesting: averaged into fixed-width buckets they flatten
  every resource series to noise, and counted as capacity they inflate idle-slot
  totals by orders of magnitude. `active/2` therefore keeps only the spans where
  telemetry was actually being written, elides the gaps between them, and reports
  elapsed *active* milliseconds. A timestamp that lands inside an elided gap
  clamps to the end of the preceding span rather than disappearing.
  """

  @default_max_idle_gap_ms 15 * 60 * 1_000

  @type span :: {integer(), integer()}
  @type t :: %{kind: :identity | :active, spans: [span()], total_ms: non_neg_integer()}

  @doc "The pass-through projection: absolute milliseconds are already the axis."
  @spec identity() :: t()
  def identity, do: %{kind: :identity, spans: [], total_ms: 0}

  @doc """
  Builds the gap-eliding projection from observed activity timestamps.

  Timestamps closer together than `:max_idle_gap_ms` (default 15 minutes) belong
  to the same active span. With no usable timestamps this degrades to `identity/0`
  so callers never have to special-case an empty scope.
  """
  @spec active([integer()], keyword()) :: t()
  def active(timestamps, opts \\ []) when is_list(timestamps) and is_list(opts) do
    gap = Keyword.get(opts, :max_idle_gap_ms, @default_max_idle_gap_ms)

    case timestamps |> Enum.filter(&is_integer/1) |> Enum.sort() do
      [] -> identity()
      sorted -> %{kind: :active, spans: spans(sorted, gap), total_ms: 0} |> put_total()
    end
  end

  @doc "Projects one wall-clock timestamp onto the axis."
  @spec project(t(), integer()) :: integer()
  def project(%{kind: :identity}, ms) when is_integer(ms), do: ms

  def project(%{kind: :active, spans: spans, total_ms: total}, ms) when is_integer(ms) do
    spans
    |> Enum.reduce_while(0, fn {low, high}, offset ->
      cond do
        # Before this span starts: the timestamp sits in the elided gap that
        # precedes it (or before all activity), so it clamps to the axis
        # position of everything already accumulated.
        ms < low -> {:halt, offset}
        ms <= high -> {:halt, offset + (ms - low)}
        true -> {:cont, offset + (high - low)}
      end
    end)
    |> min(total)
  end

  @doc "Total axis length for a `{from, to}` wall-clock window."
  @spec span_ms(t(), integer(), integer()) :: non_neg_integer()
  def span_ms(timeline, from, to) when is_integer(from) and is_integer(to) do
    max(project(timeline, to) - project(timeline, from), 0)
  end

  defp spans([first | rest], gap) do
    {spans, low, high} =
      Enum.reduce(rest, {[], first, first}, fn ms, {spans, low, high} ->
        if ms - high > gap do
          {[{low, high} | spans], ms, ms}
        else
          {spans, low, ms}
        end
      end)

    [{low, high} | spans] |> Enum.reverse()
  end

  # A scope with a single sample (or repeated identical timestamps) has zero
  # measured width. Reporting a zero-length axis would make every downstream
  # bucket division degenerate, so one millisecond stands in for "a moment".
  defp put_total(%{spans: spans} = timeline) do
    total = spans |> Enum.map(fn {low, high} -> high - low end) |> Enum.sum()
    %{timeline | total_ms: max(total, 1)}
  end
end

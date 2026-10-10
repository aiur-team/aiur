defmodule Aiur.Orchestrator.SnapshotStore.Staleness do
  @moduledoc """
  Pure staleness statistics for `Aiur.Orchestrator.SnapshotStore`: the
  load-aware freshness window and the hard age ceiling. Holds no cache key
  and reads no process state.
  """

  alias Aiur.PollCadence

  # Two tiers, and they must stay two. The adaptive window absorbs a producer
  # publishing more slowly than usual; the hard ceiling is the point past which
  # no excuse counts. If they resolved to the same number the ceiling would
  # always fire first and the adaptive mechanism would be dead code — so the
  # ceiling is deliberately twice the window's cap, exactly the 60s:120s ratio
  # the original constants expressed.
  @stale_window_intervals 2
  @stale_age_ceiling_intervals 4

  # Floors, not thresholds. Both windows below are cadence-derived
  # (`Aiur.PollCadence`); these floors only keep behaviour identical at the
  # tight cadences that predate #2064, where a cycle is a handful of seconds.
  # See `stale_window_ceiling_ms/0` and `age_ceiling_ms/0`.
  @stale_window_ceiling_floor_ms 60_000

  # Age decides staleness; a backlogged mailbox only corroborates it. An
  # Orchestrator that wedges *after* draining its mailbox publishes nothing and
  # carries no backlog, so a depth-gated rule would serve an arbitrarily old
  # fleet view as current — the exact "stale renders as current" failure this
  # read model exists to prevent. Past this ceiling the view is stale whatever
  # the mailbox says.
  #
  # The ceiling is `@stale_age_ceiling_intervals` *effective* poll intervals. An
  # idle Orchestrator only writes new snapshot input on a poll tick, so the
  # earliest honest "we should have heard by now" is a small multiple of that
  # tick — and it must sit above the adaptive window's cap, or that window can
  # never do its job. The previous constant justified itself as "four times the
  # 30s default poll cadence"; no 30s cadence has ever existed in this repo, and
  # the real default is 120s, widening to 1200s under idle plus webhook backoff.
  # The multiple of four survives; the imaginary cadence it multiplied does not.
  #
  # The floor keeps the pre-#2064 behaviour intact: at `interval_seconds: 5`
  # four cycles is 20s, so without it a 5s deployment would start flagging
  # snapshots stale six times sooner than it does today.
  @stale_age_ceiling_floor_ms 120_000

  @stale_window_margin 2

  # The backlog-corroborated path: older than the configured timeout, outside
  # the load-aware window, and the Orchestrator is visibly behind. Under
  # sustained dispatch the Orchestrator publishes on a slower cadence, so
  # `freshness_window_ms` grows to cover that cadence; an Orchestrator that has
  # gone quiet relative to its own recent cadence is still flagged stale. This
  # is one of two paths — `beyond_ceiling?/1` covers the drained-mailbox
  # wedge that this one cannot see — so mailbox depth never gates staleness on
  # its own.
  @spec behind_backlog?(term(), term(), term(), term()) :: boolean()
  def behind_backlog?(age_ms, timeout, freshness_window_ms, mailbox_depth) do
    is_integer(timeout) and timeout >= 0 and is_integer(age_ms) and age_ms >= timeout and
      is_integer(freshness_window_ms) and age_ms >= freshness_window_ms and
      is_integer(mailbox_depth) and mailbox_depth > 0
  end

  # The depth-independent floor: no snapshot older than the ceiling is ever
  # reported as current, however quiet the producer's mailbox is.
  @spec beyond_ceiling?(term()) :: boolean()
  def beyond_ceiling?(age_ms), do: is_integer(age_ms) and age_ms >= age_ceiling_ms()

  @doc false
  @spec age_ceiling_ms() :: pos_integer()
  def age_ceiling_ms do
    case Application.get_env(:aiur, :snapshot_stale_age_ceiling_ms, nil) do
      ceiling_ms when is_integer(ceiling_ms) and ceiling_ms > 0 ->
        ceiling_ms

      _unset_or_invalid ->
        PollCadence.stale_after_ms(@stale_age_ceiling_intervals,
          class: :dispatch,
          floor_ms: @stale_age_ceiling_floor_ms
        )
    end
  end

  defp stale_window_ceiling_ms do
    PollCadence.stale_after_ms(@stale_window_intervals, class: :dispatch, floor_ms: @stale_window_ceiling_floor_ms)
  end

  # The caller's tolerance is honoured exactly: `read/3` never widens a window
  # the caller asked to be narrow. Deriving the tolerance from the cadence is
  # the *caller's* job — see `AiurWeb.OperatorControlCenter.PayloadLoader` and
  # the other dashboard readers, which pass
  # `PollCadence.snapshot_tolerance_ms/1` rather than a fixed 15s. A reader that
  # genuinely wants zero tolerance (a correctness-critical read) must still be
  # able to ask for it.
  #
  # The observed-gap term widens on top of that, capped so one long pause cannot
  # widen the window indefinitely. The cap itself is cadence-derived, because a
  # fixed 60s cap clamped the adaptive window to half the 120s cadence and so
  # disabled the very mechanism meant to absorb a slower producer.
  @spec effective_window(timeout(), term()) :: timeout()
  def effective_window(timeout, gaps) when is_list(gaps) do
    case median(gaps) do
      nil ->
        timeout

      median_ms when is_integer(median_ms) and median_ms > 0 ->
        capped = min(median_ms * @stale_window_margin, stale_window_ceiling_ms())
        max(timeout, capped)

      _ ->
        timeout
    end
  end

  def effective_window(timeout, _gaps), do: timeout

  defp median([]), do: nil

  defp median(gaps) do
    sorted = Enum.sort(gaps)
    length = length(sorted)
    middle = div(length, 2)

    if rem(length, 2) == 0 do
      div(Enum.at(sorted, middle - 1) + Enum.at(sorted, middle), 2)
    else
      Enum.at(sorted, middle)
    end
  end
end

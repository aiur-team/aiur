defmodule Aiur.PollCadence do
  @moduledoc """
  The single source of truth for "how often should we have heard by now".

  Every freshness threshold in Aiur is really a statement about the poll
  cadence: a snapshot is only late once the producer has missed the rhythm it
  actually keeps. Expressing those thresholds as absolute milliseconds silently
  decouples them the moment the cadence moves — which is exactly what happened
  when `polling.interval_seconds` went from 5 to 120 (#2064) and every
  threshold kept its old, 24x-too-tight value.

  ## The effective interval is not the configured one

  `TrackerHealth.poll_schedule/2` composes three multipliers on top of
  `polling.interval_seconds`:

    * `webhooks.poll_widen_factor` — applied only to a repo proven
      webhook-backed
    * `polling.idle_widen_factor` — applied while no agent is running
    * GitHub's own `X-Poll-Interval` / connectivity backoff floors

  At the shipped defaults that is `120s * 2.0 * 5.0 = 1200s`, which is what
  `aiur status` reports as `interval=1200s base=120s factor=5.0x`. A threshold
  derived from the *base* interval therefore calls a correctly-idling fleet
  stale for 90% of every cycle.

  So the dispatcher publishes the interval it actually scheduled, and every
  consumer derives from that.

  ## Reading the effective interval

  `effective_interval_ms/1` answers, in order:

    1. an explicit `:effective_interval_ms` option — for a caller that already
       holds a snapshot's own polling facts
    2. the value the dispatcher last published (the live daemon case)
    3. `widest_configured_interval_ms/1` — the widest cadence the current
       configuration permits

  Step 3 is deliberately the *widest*, not the base. Before the first poll tick
  nothing has observed the cadence, and the failure modes are asymmetric: too
  narrow labels healthy data stale (the regression this module exists to fix),
  too wide only delays a label that the very next tick corrects with the real
  value. It is also unreachable in a running daemon, where step 2 always
  answers.

  ## Deriving a threshold

  `stale_after_ms/2` returns `multiple * effective_interval_ms`, optionally
  floored. The floor is how a caller keeps its behaviour unchanged at a tight
  cadence: at `interval_seconds: 5` a two-cycle threshold is 10s, so a caller
  that used to allow 120s passes `floor_ms: 120_000` and is unaffected there
  while still widening as the cadence widens.
  """

  alias Aiur.Config
  alias Aiur.Webhooks.IntervalPolicy

  @effective_key {__MODULE__, :effective_interval_ms}

  # Mirrors `Aiur.Config.Schema.Polling`'s own default. Used only when the
  # configuration cannot be read at all.
  @fallback_interval_ms 120_000

  # An idle Orchestrator only writes new snapshot input on a poll tick, so two
  # missed ticks is the earliest moment "we should have heard by now" is true.
  @snapshot_tolerance_intervals 2

  # Deliberately absolute, and the one threshold here that must be.
  #
  # The published interval composes GitHub's `X-Poll-Interval`, which
  # `TrackerHealth.note_github_poll_interval/3` stores verbatim and no code
  # caps. A remote server could therefore name any cadence and, through this
  # module, decide how long Aiur calls its own data fresh — so throttling us
  # would also be how staleness stops being reported, at the moment it matters
  # most.
  #
  # An hour is a wall-clock statement, not a cadence one: past an hour the
  # operator needs to be told the fleet view is old whatever the poller
  # believes. At the shipped 1200s effective interval this is inert; it binds
  # only when something upstream asks us to poll less than once an hour.
  @max_effective_interval_ms 3_600_000

  @doc """
  Records the interval the dispatcher actually scheduled.

  Written to `:persistent_term` so any process — dashboard reader, Stream Deck
  projection, CLI — can read it without a message to the Orchestrator. Writes
  are skipped when the value is unchanged, so a steady cadence costs one write
  in total rather than one per tick.
  """
  @spec publish_effective_interval_ms(term()) :: :ok
  def publish_effective_interval_ms(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    if :persistent_term.get(@effective_key, nil) != interval_ms do
      :persistent_term.put(@effective_key, interval_ms)
    end

    :ok
  end

  # A schedule that is not a positive interval — an immediate reschedule after
  # an operator wake, say — leaves the last real cadence in force rather than
  # erasing it. A momentary "poll now" is not evidence the rhythm changed, and
  # dropping to the cold-start fallback would move every threshold for one tick.
  def publish_effective_interval_ms(_interval_ms), do: :ok

  @doc false
  @spec forget_effective_interval_ms() :: :ok
  def forget_effective_interval_ms do
    :persistent_term.erase(@effective_key)
    :ok
  end

  @doc """
  What the dispatcher has actually published, or `nil` if it has not yet.

  `effective_interval_ms/1` answers a number either way, which is right for a
  staleness threshold. A caller deriving a *cadence* needs to tell the two
  apart, because the cold-start fallback is deliberately the widest cadence the
  configuration permits and "widest" is the wrong default for something that
  fires.
  """
  @spec published_effective_interval_ms() :: pos_integer() | nil
  def published_effective_interval_ms do
    positive_integer(:persistent_term.get(@effective_key, nil))
  end

  @doc """
  The cadence actually in force, including idle and webhook widening, bounded by
  `@max_effective_interval_ms` so a remote `X-Poll-Interval` cannot decide how
  long Aiur calls its own data fresh.
  """
  @spec effective_interval_ms(keyword()) :: pos_integer()
  def effective_interval_ms(opts \\ []) do
    interval_ms =
      with nil <- positive_integer(Keyword.get(opts, :effective_interval_ms)),
           nil <- positive_integer(:persistent_term.get(@effective_key, nil)) do
        widest_configured_interval_ms(opts)
      end

    min(interval_ms, @max_effective_interval_ms)
  end

  @doc """
  The configured base interval, before any widening.
  """
  @spec base_interval_ms(keyword()) :: pos_integer()
  def base_interval_ms(opts \\ []) do
    case positive_integer(Keyword.get(opts, :base_interval_ms)) do
      nil -> configured_base_interval_ms()
      base_ms -> base_ms
    end
  end

  @doc """
  The widest cadence the current configuration permits: base interval times the
  webhook widen factor times the idle widen factor.

  This is the cold-start answer, used before the dispatcher has published a
  real one.
  """
  @spec widest_configured_interval_ms(keyword()) :: pos_integer()
  def widest_configured_interval_ms(opts \\ []) do
    base_ms = base_interval_ms(opts)

    base_ms
    |> IntervalPolicy.widen(webhook_widen_factor(opts))
    |> IntervalPolicy.widen(idle_widen_factor(opts))
  end

  @doc """
  A "we should have heard by now" threshold, in milliseconds.

  `multiple` is how many effective cycles may pass before the data is late.
  Pass `floor_ms:` to keep an existing absolute behaviour at tight cadences.

  An explicit `floor_ms: 0` means **zero tolerance** and is returned as-is: a
  correctness-critical reader that wants no staleness at all must be able to say
  so, and quietly widening it to a cycle would be the worst possible way to
  ignore that. Only an absent or invalid floor falls back to `1`.
  """
  @spec stale_after_ms(number(), keyword()) :: non_neg_integer()
  def stale_after_ms(multiple, opts \\ []) when is_number(multiple) and multiple > 0 do
    case Keyword.get(opts, :floor_ms) do
      0 ->
        0

      floor_ms ->
        derived = opts |> effective_interval_ms() |> Kernel.*(multiple) |> round()
        max(derived, positive_integer(floor_ms) || 1)
    end
  end

  @doc """
  The staleness a dashboard reader tolerates before a fleet view is presented
  as last-known-good rather than current.

  `floor_ms` is the configured `snapshot_timeout_ms` (default 15s). It stays a
  floor rather than the answer: at the 120s poll a fixed 15s tolerance held for
  roughly 87% of every cycle, so a healthy fleet announced staleness
  continuously. Deriving it means the notice appears when the producer is
  actually behind its own rhythm, and nowhere else.

  `snapshot_tolerance_ms(0)` is honoured as zero, so an endpoint configured with
  `snapshot_timeout_ms: 0` still gets the zero-tolerance read it asked for.
  """
  @spec snapshot_tolerance_ms(non_neg_integer()) :: non_neg_integer()
  def snapshot_tolerance_ms(floor_ms \\ 15_000) do
    stale_after_ms(@snapshot_tolerance_intervals, floor_ms: floor_ms)
  end

  @doc """
  `stale_after_ms/2` in whole seconds, rounded up so a sub-second threshold
  never becomes zero.
  """
  @spec stale_after_seconds(number(), keyword()) :: pos_integer()
  def stale_after_seconds(multiple, opts \\ []) when is_number(multiple) and multiple > 0 do
    multiple |> stale_after_ms(opts) |> Kernel./(1_000) |> Float.ceil() |> trunc() |> max(1)
  end

  defp configured_base_interval_ms do
    case Config.settings() do
      {:ok, %{polling: %{interval_seconds: seconds}}} when is_integer(seconds) and seconds > 0 ->
        seconds * 1_000

      _unavailable ->
        @fallback_interval_ms
    end
  end

  defp webhook_widen_factor(opts) do
    opts
    |> Keyword.get_lazy(:webhook_widen_factor, fn -> configured_factor(:webhooks, :poll_widen_factor) end)
    |> then(&IntervalPolicy.widen_factor(widen_factor: &1))
  end

  defp idle_widen_factor(opts) do
    opts
    |> Keyword.get_lazy(:idle_widen_factor, fn -> configured_factor(:polling, :idle_widen_factor) end)
    |> then(&IntervalPolicy.widen_factor(widen_factor: &1))
  end

  defp configured_factor(section, key) do
    case Config.settings() do
      {:ok, settings} -> settings |> Map.get(section, %{}) |> Map.get(key) || 1.0
      _unavailable -> 1.0
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil
end

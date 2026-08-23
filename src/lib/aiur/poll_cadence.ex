defmodule Aiur.PollCadence do
  @moduledoc """
  The single source of truth for "how often should we have heard by now".

  Every freshness threshold in Aiur is really a statement about the poll
  cadence: a snapshot is only late once the producer has missed the rhythm it
  actually keeps. Expressing those thresholds as absolute milliseconds silently
  decouples them the moment the cadence moves — which is exactly what happened
  when `polling.interval_seconds` went from 5 to 120 (#2064) and every
  threshold kept its old, 24x-too-tight value.

  ## Poll classes

  Since #2309 the cadence is **per state class**, not a single global number.
  The state Aiur polls for is not equally urgent, and the cheap state is not the
  expensive state: the tracker poll that dispatches work is a conditional REST
  read (mostly free `304`s) and must stay prompt, while the GraphQL pollers that
  inspect CI, comments and Build Order cost real points every time and can safely
  run far less often. Each class resolves its own interval; `polling.intervals`
  names a class and overrides `polling.interval_seconds` for that class only, so
  an operator can run planning at 10 minutes while dispatch stays at 2:

  ```yaml
  polling:
    interval_seconds: 120        # remains the default for any unlisted class
    intervals:
      dispatch: 120
      ci: 60
      review: 300
      planning: 600
  ```

  The classes are:

    * `:dispatch` — the tracker poll (open issues, `agent:*` labels) and every
      threshold derived from the orchestrator snapshot it writes. Cheap and
      urgent.
    * `:ci` — check state on a pull request with work in flight. Expensive and
      urgent, but only while a PR is actually in flight (the loop is
      demand-scoped).
    * `:review` — comments and review threads. Expensive, moderately urgent.
    * `:planning` — Build Order catalog, pack status, ad-hoc listings.
      Expensive per call and not urgent.
    * `:firehose` — repo events. Self-regulating via GitHub's `X-Poll-Interval`;
      the class exists so status can show its configured cadence, not to change
      its loop.

  **A consumer derives from the class it means.** `stale_after_ms(3, class:
  :dispatch)` and `stale_after_ms(3, class: :planning)` can legitimately answer
  different numbers once `polling.intervals` diverges the classes. Every
  cadence-reading call site names its class; none reads a bare global interval.
  The default class is `:dispatch` (the historical "the interval"), so an
  un-named call keeps today's meaning.

  ## The effective interval is not the configured one

  `TrackerHealth.poll_schedule/2` composes three multipliers on top of a
  class's base interval:

    * `webhooks.poll_widen_factor` — applied only to a repo proven
      webhook-backed
    * `polling.idle_widen_factor` — applied while no agent is running
    * GitHub's own `X-Poll-Interval` / connectivity backoff floors

  At the shipped defaults that is `120s * 2.0 * 5.0 = 1200s`, which is what
  `aiur status` reports as `interval=1200s base=120s factor=5.0x`. A threshold
  derived from the *base* interval therefore calls a correctly-idling fleet
  stale for 90% of every cycle.

  So the dispatcher publishes the interval each class actually schedules, and
  every consumer derives from that. The widening composition is **uniform across
  classes**: a class's effective interval is its class base times the same
  webhook and idle factors. With no `polling.intervals` map every class shares
  the same base, so all classes resolve to the single value today's consumers
  read — existing configs are an exact no-op.

  ## Reading the effective interval

  `effective_interval_ms/1` answers, in order:

    1. an explicit `:effective_interval_ms` option — for a caller that already
       holds a snapshot's own polling facts
    2. the value the dispatcher last published for that class (inheriting the
       `:dispatch` value until the class has its own)
    3. `widest_configured_interval_ms/1` — the widest cadence the current
       configuration permits for that class

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

  # The classes that resolve their own cadence. The schema mirrors this list
  # (as strings) for `polling.intervals` validation; a test keeps the two in
  # sync.
  @poll_classes [:dispatch, :ci, :review, :planning, :firehose]
  # `:dispatch` is the historical "the interval": an un-named call keeps today's
  # meaning, and a class the dispatcher has not published yet inherits the
  # dispatch value rather than answering nil (backward compatibility and the
  # invariant that all classes share the dispatch cadence until they diverge).
  @default_class :dispatch

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
  The poll classes that resolve their own cadence.
  """
  @spec poll_classes() :: [atom()]
  def poll_classes, do: @poll_classes

  @doc """
  Records the interval the dispatcher actually scheduled for one class.

  Written to `:persistent_term` so any process — dashboard reader, Stream Deck
  projection, CLI — can read it without a message to the Orchestrator. Writes
  are skipped when the value is unchanged, so a steady cadence costs one write
  in total rather than one per tick.

  The optional `class:` names the class; the default is `:dispatch`, so an
  un-named publish keeps the historical single-value meaning.
  """
  @spec publish_effective_interval_ms(term(), keyword()) :: :ok
  def publish_effective_interval_ms(interval_ms, opts \\ [])

  def publish_effective_interval_ms(interval_ms, opts)
      when is_integer(interval_ms) and interval_ms > 0 do
    class = class_from(opts)
    key = effective_key(class)

    if :persistent_term.get(key, nil) != interval_ms do
      :persistent_term.put(key, interval_ms)
    end

    :ok
  end

  # A schedule that is not a positive interval — an immediate reschedule after
  # an operator wake, say — leaves the last real cadence in force rather than
  # erasing it. A momentary "poll now" is not evidence the rhythm changed, and
  # dropping to the cold-start fallback would move every threshold for one tick.
  def publish_effective_interval_ms(_interval_ms, _opts), do: :ok

  @doc false
  @spec forget_effective_interval_ms() :: :ok
  def forget_effective_interval_ms do
    for class <- @poll_classes, do: :persistent_term.erase(effective_key(class))
    :persistent_term.erase(@effective_key)
    :ok
  end

  @doc """
  What the dispatcher has actually published for a class, or `nil` if it has
  not yet.

  A class the dispatcher has not published inherits the `:dispatch` value, since
  until it diverges every class shares the dispatch cadence. `effective_interval_ms/1`
  answers a number either way, which is right for a staleness threshold. A caller
  deriving a *cadence* needs to tell the two apart, because the cold-start
  fallback is deliberately the widest cadence the configuration permits and
  "widest" is the wrong default for something that fires.
  """
  @spec published_effective_interval_ms(keyword()) :: pos_integer() | nil
  def published_effective_interval_ms(opts \\ []) do
    class = class_from(opts)
    published_for(class)
  end

  @doc """
  The cadence actually in force for a class, including idle and webhook
  widening, bounded by `@max_effective_interval_ms` so a remote `X-Poll-Interval`
  cannot decide how long Aiur calls its own data fresh.

  `class:` names the poll class; the default is `:dispatch`.
  """
  @spec effective_interval_ms(keyword()) :: pos_integer()
  def effective_interval_ms(opts \\ []) do
    class = class_from(opts)

    interval_ms =
      with nil <- positive_integer(Keyword.get(opts, :effective_interval_ms)),
           nil <- positive_integer(published_for(class)) do
        widest_configured_interval_ms(opts)
      end

    min(interval_ms, @max_effective_interval_ms)
  end

  @doc """
  The configured base interval for a class, before any widening.

  A class with an entry in `polling.intervals` uses that entry; any other class
  (or an absent map) falls back to `polling.interval_seconds`. `class:` names
  the class; the default is `:dispatch`.
  """
  @spec base_interval_ms(keyword()) :: pos_integer()
  def base_interval_ms(opts \\ []) do
    case positive_integer(Keyword.get(opts, :base_interval_ms)) do
      nil -> configured_base_interval_ms(class_from(opts))
      base_ms -> base_ms
    end
  end

  @doc """
  The widest cadence the current configuration permits for a class: its base
  interval times the webhook widen factor times the idle widen factor.

  This is the cold-start answer, used before the dispatcher has published a
  real one. `class:` names the class; the default is `:dispatch`.
  """
  @spec widest_configured_interval_ms(keyword()) :: pos_integer()
  def widest_configured_interval_ms(opts \\ []) do
    base_ms = base_interval_ms(opts)

    base_ms
    |> IntervalPolicy.widen(webhook_widen_factor(opts))
    |> IntervalPolicy.widen(idle_widen_factor(opts))
  end

  @doc """
  The live cadence for every poll class, keyed by class.

  The status surface uses this to show an operator, without reading config, that
  planning is at 10 minutes while dispatch is at 2. Each class resolves exactly
  as `effective_interval_ms/1` would with that class named.
  """
  @spec effective_intervals(keyword()) :: %{required(atom()) => pos_integer()}
  def effective_intervals(opts \\ []) do
    Map.new(@poll_classes, fn class ->
      {class, effective_interval_ms(Keyword.put(opts, :class, class))}
    end)
  end

  @doc """
  Whether a loop that last fired at `last_started_ms` should skip because it is
  still inside its class cadence.

  A poll loop that rides on the dispatch tick (comment poll, CI poll) throttles
  itself to the cadence of the class it serves (#2309). Two limits keep this a
  no-op where it must be:

    * `last_started_ms` is `nil` (never fired) — run now;
    * the class has no published cadence yet (cold start, or a harness without
      a live dispatcher) — run every tick, exactly as before the throttle.

  Once the dispatcher has published the class cadence, the gate binds only when
  that cadence is wider than the dispatch tick the loop rides on; at default
  config the published class cadence equals the dispatch tick, so the gate never
  skips a tick the loop would have run on.
  """
  @spec within_class_cadence?(non_neg_integer() | nil, non_neg_integer(), atom()) :: boolean()
  def within_class_cadence?(last_started_ms, now_ms, class) when is_integer(last_started_ms) do
    case published_effective_interval_ms(class: class) do
      cadence_ms when is_integer(cadence_ms) and cadence_ms > 0 -> now_ms - last_started_ms < cadence_ms
      _unpublished -> false
    end
  end

  def within_class_cadence?(_last_started_ms, _now_ms, _class), do: false

  @doc """
  A "we should have heard by now" threshold, in milliseconds.

  `multiple` is how many effective cycles may pass before the data is late.
  Pass `floor_ms:` to keep an existing absolute behaviour at tight cadences.

  An explicit `floor_ms: 0` means **zero tolerance** and is returned as-is: a
  correctness-critical reader that wants no staleness at all must be able to say
  so, and quietly widening it to a cycle would be the worst possible way to
  ignore that. Only an absent or invalid floor falls back to `1`.

  `class:` names the poll class the threshold is about; the default is
  `:dispatch`.
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

  Dashboard readers of the orchestrator snapshot name `class: :dispatch`, the
  class the snapshot's producer ticks on.
  """
  @spec snapshot_tolerance_ms(non_neg_integer(), keyword()) :: non_neg_integer()
  def snapshot_tolerance_ms(floor_ms \\ 15_000, opts \\ []) do
    stale_after_ms(@snapshot_tolerance_intervals, Keyword.put(opts, :floor_ms, floor_ms))
  end

  @doc """
  `stale_after_ms/2` in whole seconds, rounded up so a sub-second threshold
  never becomes zero. `class:` passes through to `stale_after_ms/2`.
  """
  @spec stale_after_seconds(number(), keyword()) :: pos_integer()
  def stale_after_seconds(multiple, opts \\ []) when is_number(multiple) and multiple > 0 do
    multiple |> stale_after_ms(opts) |> Kernel./(1_000) |> Float.ceil() |> trunc() |> max(1)
  end

  defp effective_key(class), do: {@effective_key, class}

  defp class_from(opts) do
    case Keyword.get(opts, :class, @default_class) do
      class when class in @poll_classes -> class
      _other -> @default_class
    end
  end

  # A class the dispatcher has not published inherits the `:dispatch` value
  # (the historical single value), so an un-diverged class and a partially
  # published test keep reading the cadence they always read.
  defp published_for(class) do
    case :persistent_term.get(effective_key(class), nil) do
      nil when class != @default_class -> :persistent_term.get(effective_key(@default_class), nil)
      value -> value
    end
  end

  defp configured_base_interval_ms(class) do
    case Config.settings() do
      {:ok, %{polling: %{interval_seconds: seconds}}} when is_integer(seconds) and seconds > 0 ->
        case Map.fetch(Config.poll_intervals(), class) do
          {:ok, class_seconds} when is_integer(class_seconds) and class_seconds > 0 -> class_seconds * 1_000
          _unset_or_invalid -> seconds * 1_000
        end

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

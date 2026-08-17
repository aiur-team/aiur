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

  def publish_effective_interval_ms(_interval_ms), do: :ok

  @doc false
  @spec forget_effective_interval_ms() :: :ok
  def forget_effective_interval_ms do
    :persistent_term.erase(@effective_key)
    :ok
  end

  @doc """
  The cadence actually in force, including idle and webhook widening.
  """
  @spec effective_interval_ms(keyword()) :: pos_integer()
  def effective_interval_ms(opts \\ []) do
    with nil <- positive_integer(Keyword.get(opts, :effective_interval_ms)),
         nil <- positive_integer(:persistent_term.get(@effective_key, nil)) do
      widest_configured_interval_ms(opts)
    end
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
  """
  @spec stale_after_ms(number(), keyword()) :: pos_integer()
  def stale_after_ms(multiple, opts \\ []) when is_number(multiple) and multiple > 0 do
    derived = opts |> effective_interval_ms() |> Kernel.*(multiple) |> round()
    floor_ms = positive_integer(Keyword.get(opts, :floor_ms)) || 1

    max(derived, floor_ms)
  end

  @doc """
  `stale_after_ms/2` in whole seconds, rounded up so a sub-second threshold
  never becomes zero.
  """
  @spec stale_after_seconds(number(), keyword()) :: pos_integer()
  def stale_after_seconds(multiple, opts \\ []) do
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
    case Keyword.fetch(opts, :webhook_widen_factor) do
      {:ok, factor} -> IntervalPolicy.widen_factor(widen_factor: factor)
      :error -> IntervalPolicy.widen_factor([])
    end
  end

  defp idle_widen_factor(opts) do
    factor =
      Keyword.get_lazy(opts, :idle_widen_factor, fn ->
        case Config.settings() do
          {:ok, %{polling: %{idle_widen_factor: factor}}} -> factor
          _unavailable -> 1.0
        end
      end)

    IntervalPolicy.widen_factor(widen_factor: factor)
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil
end

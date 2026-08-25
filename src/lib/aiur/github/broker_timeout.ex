defmodule Aiur.GitHub.BrokerTimeout do
  @moduledoc """
  Turns the budget-broker-timeout retry rate into a first-class signal (#2464).

  #2457/#2459 made dispatch survive a budget broker timeout by backing off and
  retrying. That is correct, but it also removed the only previous detector for
  the broker fault: the terminated runs (`workspace_github_connectivity_failed`)
  that used to make 28 timeouts in ten minutes countable. After the retry fix
  the fleet looks healthy and nothing says the broker is still timing out. This
  module is the replacement signal.

  Two outputs, one on the retry path and one on a dwelled threshold:

  * **`system.github.budget_broker_retry`** — emitted once per backoff. This is
    the raw, queryable count: a future investigation can establish the rate from
    the persisted alert ledger without having been watching at the time (that is
    precisely what was missing when #2457 was filed). It is `needs_attention:
    false`, because the individual retry is uninteresting.
  * **`system.github.budget_broker_degraded`** — emitted exactly once, after a
    dwell, when the retry rate stays elevated. The unit of interest is "the
    broker has been degraded for N minutes", not "a request retried". A single
    isolated timeout never crosses the threshold and produces nothing; the
    `.resolved` sibling fires when the rate drops back below it.

  This is the dwell treatment #2434 and #2449 established for prewarm holds and
  capacity starvation, applied to the broker-timeout rate: a momentary blip does
  not page anyone, a genuine sustained degradation does — once.

  The window, threshold and dwell are all data (config), never magic numbers in
  this module, so an operator who measures a quiet-period baseline can derive
  the threshold from observation rather than a guess.

  `record/0` runs on the GitHub retry path and must never become a request
  failure; it casts to this process (fire-and-forget) and swallows a down
  process. `check/0` is driven by this process's own periodic timer.
  """

  use GenServer

  alias Aiur.{Alerts, Config}

  @retry_topic "system.github.budget_broker_retry"
  @degraded_topic "system.github.budget_broker_degraded"
  @resolution_topic "system.github.budget_broker_degraded.resolved"

  # How often the monitor re-evaluates the sliding-window rate and dwell. The
  # dwell itself is config; this is only the granularity at which it is checked.
  @check_interval_ms 30_000

  @default_window_seconds 300
  @default_threshold 5
  @default_dwell_seconds 600

  defstruct events: [], since_ms: nil, alert_active: false, check_interval_ms: @check_interval_ms, emit_fun: &Alerts.emit_system/2

  @type state :: %__MODULE__{}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Records one budget-broker-timeout retry.

  Casts a timestamp into this process's sliding window and emits the persisted
  `system.github.budget_broker_retry` telemetry event. Fire-and-forget: a
  monitor that is not running (or a config that cannot be read) must never take
  down the GitHub retry path it observes.
  """
  @spec record() :: :ok
  def record, do: record(System.monotonic_time(:millisecond))

  @doc false
  @spec record(integer(), keyword()) :: :ok
  def record(now_ms, opts \\ []) when is_integer(now_ms) and is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.cast(name, {:record, now_ms})
    :ok
  rescue
    ArgumentError -> :ok
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Re-evaluates the sliding-window rate and raises / clears the degraded alert.

  Also the body of this process's periodic timer. Public so tests can drive the
  dwell deterministically without waiting for the timer.
  """
  @spec check() :: :ok
  def check, do: check(System.monotonic_time(:millisecond))

  @doc false
  @spec check(integer(), keyword()) :: :ok
  def check(now_ms, opts \\ []) when is_integer(now_ms) and is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, {:check, now_ms})
    :ok
  rescue
    ArgumentError -> :ok
  catch
    :exit, _reason -> :ok
  end

  @doc "The number of retries currently inside the sliding window."
  @spec count() :: non_neg_integer()
  def count, do: count(System.monotonic_time(:millisecond))

  @doc false
  @spec count(integer(), keyword()) :: non_neg_integer()
  def count(now_ms, opts \\ []) when is_integer(now_ms) and is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, {:count, now_ms})
  rescue
    ArgumentError -> 0
  catch
    :exit, _reason -> 0
  end

  @doc false
  # Clears all recorded retries and the alert latch. Test support.
  @spec reset() :: :ok
  def reset, do: reset([])

  @doc false
  @spec reset(keyword()) :: :ok
  def reset(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, :reset)
    :ok
  rescue
    ArgumentError -> :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    check_interval_ms =
      Keyword.get(opts, :check_interval_ms, Application.get_env(:aiur, :broker_timeout_check_interval_ms, @check_interval_ms))

    emit_fun = Keyword.get(opts, :emit_fun, &Alerts.emit_system/2)

    state = %__MODULE__{check_interval_ms: check_interval_ms, emit_fun: emit_fun}
    {:ok, maybe_schedule_check(state)}
  end

  @impl true
  def handle_cast({:record, now_ms}, state) do
    {:noreply, record_event(state, now_ms)}
  end

  @impl true
  def handle_call({:check, now_ms}, _from, state) do
    {:reply, :ok, evaluate(state, now_ms)}
  end

  def handle_call({:count, now_ms}, _from, state) do
    state = prune_events(state, now_ms)
    {:reply, length(state.events), state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | events: [], since_ms: nil, alert_active: false}}
  end

  @impl true
  def handle_info(:check, state) do
    state = evaluate(state, System.monotonic_time(:millisecond))
    {:noreply, maybe_schedule_check(state)}
  end

  defp record_event(%__MODULE__{events: events} = state, now_ms) do
    safe_emit(fn -> emit_retry_event(state) end)
    %{state | events: [now_ms | prune_older(events, now_ms)]}
  end

  # The raw telemetry event is the queryable count (#2464 acceptance 3). It is
  # deliberately not an attention: the individual retry is uninteresting, only
  # the rate is.
  defp emit_retry_event(state) do
    state.emit_fun.(@retry_topic,
      message: "GitHub budget broker timed out; the operation is backed off and will retry",
      reason: "Budget broker timeout retry recorded",
      severity: "info",
      needs_attention: false
    )
  end

  # The dwelled, thresholded degraded alert — exactly one per episode, after the
  # rate has stayed elevated for `dwell`. Mirrors the capacity-starvation latch
  # (#2447): `since_ms` is stamped on the first elevated check and reset the
  # moment the rate drops, so a blip that clears within the bound raises nothing.
  defp evaluate(state, now_ms) do
    state = prune_events(state, now_ms)

    if degraded?(state) do
      evaluate_degraded(state, now_ms)
    else
      evaluate_recovered(state)
    end
  end

  # Degraded: stamp the dwell start on the first elevated check; once the rate
  # has stayed elevated for the dwell, emit exactly one alert and latch.
  defp evaluate_degraded(state, now_ms) do
    since_ms = state.since_ms || now_ms

    if not state.alert_active and now_ms - since_ms >= dwell_ms() do
      safe_emit(fn -> emit_degraded(state, since_ms, now_ms) end)
      %{state | since_ms: since_ms, alert_active: true}
    else
      %{state | since_ms: since_ms}
    end
  end

  # Recovered: emit the resolution (when an alert was live) and clear the latch
  # so a later episode re-arms it.
  defp evaluate_recovered(state) do
    if state.alert_active, do: safe_emit(fn -> emit_resolved(state) end)
    %{state | since_ms: nil, alert_active: false}
  end

  # `state.events` is already pruned to the window by `prune_events/2`.
  defp degraded?(state), do: length(state.events) >= threshold()

  defp emit_degraded(state, since_ms, now_ms) do
    elapsed_s = div(now_ms - since_ms, 1_000)

    state.emit_fun.(@degraded_topic,
      message: "GitHub budget broker has been degraded for #{elapsed_s}s (#{length(state.events)} timeouts in the window)",
      reason: "Budget broker retry rate sustained above threshold for #{elapsed_s}s",
      severity: "warning",
      needs_attention: true
    )
  end

  defp emit_resolved(state) do
    state.emit_fun.(@resolution_topic,
      message: "GitHub budget broker timeout rate recovered; retries back below threshold",
      reason: "Budget broker retry rate dropped back below threshold",
      severity: "info",
      needs_attention: false
    )
  end

  defp prune_events(%__MODULE__{events: events} = state, now_ms) do
    %{state | events: prune_older(events, now_ms)}
  end

  defp prune_older(events, now_ms) do
    cutoff = now_ms - window_ms()
    Enum.filter(events, &(&1 >= cutoff))
  end

  defp maybe_schedule_check(%__MODULE__{check_interval_ms: interval} = state) when interval > 0 do
    Process.send_after(self(), :check, interval)
    state
  end

  defp maybe_schedule_check(state), do: state

  # An observability failure must never take down the monitor itself — its
  # sliding-window rate is the signal, and losing it to a ledger hiccup would
  # recreate the exact blind spot #2464 exists to close.
  defp safe_emit(emit) do
    emit.()
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp window_ms, do: config_integer(&Config.budget_broker_rate_window_seconds/0, @default_window_seconds) * 1_000
  defp threshold, do: config_integer(&Config.budget_broker_degraded_retry_threshold/0, @default_threshold)
  defp dwell_ms, do: config_integer(&Config.budget_broker_degraded_alert_after_seconds/0, @default_dwell_seconds) * 1_000

  # Config is the source of truth; a config that cannot be read must degrade to
  # a sane default rather than crash the monitor that guards the retry signal.
  defp config_integer(read, default) do
    case read.() do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  rescue
    _error -> default
  end
end

defmodule Aiur.GitHub.ViewStateSweep do
  @moduledoc """
  The single slow cadence behind every view-state source.

  ## Why exactly one timer, and why it is not zero

  Webhook deliveries are free and arrive first, so view state should ride on
  them and cost nothing. It cannot cost nothing, because **deliveries are lost**.
  Measured here: 9 of 100 deliveries returned 502 during a daemon restart,
  GitHub retried none of them, and none arrived later — 2 `issue_comment` and 7
  `check_run`. That is why the store is a cache with reconciliation and never
  the system of record, and it is the entire reason this timer exists.

  So the sweep has one job: **recover a delivery that was lost.** It is not a
  refresh cadence, it is not how a page gets its data, and it must never be
  tuned as though shortening it made anything fresher. A change that arrives is
  already free; the sweep only closes the gap left by one that did not.

  ## What it replaced

  Three view-state sources each ran their own timer against GitHub, none of them
  with a config key an operator could reach:

    * `Aiur.OpenTicketSource` — the whole open backlog, every 120s
    * `Aiur.BuildOrder.AdHocSource` — a labelled issue listing, every 60s
    * `Aiur.BuildOrder.PackStatus` — a GraphQL pack read, every 300s

  Three independent cadences against one API, at three intervals nobody chose
  together, is how the burn this ticket exists to remove was built. They now hold
  no timer at all: this process ticks and asks each of them to reconcile, and
  each one still refreshes on demand when a real need arrives.

  ## Bounding the sweep rather than tightening it

  The sweep never skips itself, and it never advances a suppression watermark, so
  there is no window in which a gap cannot be seen. Suppression is decided per
  resource identity plus `version` (see `Aiur.GitHub.ResourceStore`), which is
  what lets a resource whose delivery was lost recover on the very next tick even
  though a newer sibling was delivered and marked.
  """

  use GenServer

  require Logger

  alias Aiur.Config

  # A source is anything holding view state that GitHub is the origin of. Named
  # here rather than self-registering, so the set of things that can generate
  # view-state traffic is readable in one place and a new one cannot be added
  # without this list changing.
  @sources [
    Aiur.OpenTicketSource,
    Aiur.BuildOrder.AdHocSource,
    Aiur.BuildOrder.PackStatus
  ]

  @default_interval_ms :timer.minutes(15)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The sources this sweep reconciles."
  @spec sources() :: [module()]
  def sources, do: @sources

  @doc "Runs one sweep now and answers the sources it reconciled (test/support)."
  @spec sweep_now(GenServer.server()) :: [module()]
  def sweep_now(server \\ __MODULE__) do
    GenServer.call(server, :sweep_now, 30_000)
  catch
    :exit, _reason -> []
  end

  @doc "The interval this sweep is running at, in milliseconds."
  @spec interval_ms(GenServer.server()) :: pos_integer() | nil
  def interval_ms(server \\ __MODULE__) do
    GenServer.call(server, :interval_ms)
  catch
    :exit, _reason -> nil
  end

  @impl true
  def init(opts) do
    state = %{
      interval: Keyword.get(opts, :interval_ms) || configured_interval_ms(),
      sources: Keyword.get(opts, :sources, @sources)
    }

    if Keyword.get(opts, :sweep_on_start, false), do: send(self(), :sweep)
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:sweep_now, _from, state), do: {:reply, sweep(state), state}
  def handle_call(:interval_ms, _from, state), do: {:reply, state.interval, state}

  @impl true
  def handle_info(:sweep, state) do
    sweep(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A source that is not running is skipped rather than started: the sweep is
  # recovery for state somebody is holding, and there is nothing to recover for a
  # source this deployment does not run at all.
  defp sweep(state) do
    Enum.filter(state.sources, fn source ->
      if Process.whereis(source) do
        source.refresh()
        true
      else
        false
      end
    end)
  end

  defp schedule(%{interval: interval}) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :sweep, interval)
  end

  defp schedule(_state), do: :ok

  # A configuration fault must not take the sweep down: without it a lost
  # delivery is unrecoverable, which is strictly worse than sweeping at the
  # default interval.
  defp configured_interval_ms do
    :timer.seconds(Config.view_state_sweep_seconds())
  rescue
    error ->
      Logger.warning("ViewStateSweep could not read its interval; using the default reason=#{inspect(error)}")
      @default_interval_ms
  catch
    _kind, _reason -> @default_interval_ms
  end
end

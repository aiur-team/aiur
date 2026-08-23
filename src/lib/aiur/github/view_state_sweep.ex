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

  So the sweep has one job: **recover what a free writer did not deliver.** It
  is not a refresh cadence and it must never be tuned as though shortening it
  made anything fresher.

  ## Demand-driven: it refreshes only what somebody is watching

  The three sources are read exclusively by `aiur_web`. Two of them —
  `Aiur.OpenTicketSource` and `Aiur.BuildOrder.AdHocSource` — are reconciled
  **only while at least one LiveView session is watching them**. A watching
  session is a demander, registered when the page subscribes to the source
  (`OpenTicketSource.subscribe/0` and the Build Order sources' `subscribe/0`,
  both already called on mount); a monitor releases it when the session dies.

  Two consequences follow from that shape:

    * Opening the page that needs a source renders its held snapshot first, and
      the first demander also buys one immediate refresh — so a freshly opened
      page does not wait a full interval for its first fresh read.
    * With no session open there is no demander, and the sweep refreshes
      neither of those two sources. An idle daemon with no dashboard session
      open makes zero requests from either of them, which is the entire reason
      this gate exists: a 900-second sweep against a 30-second cache TTL is a
      guaranteed cache miss, so the only honest reason to run it at all is that
      someone is looking.

  `Aiur.BuildOrder.PackStatus` is the deliberate exception: it reports demanded
  unconditionally (`demanded?/0` answers `true`), so the sweep reconciles it on
  every tick whether or not a page is open. It writes the daemon-owned
  `status.json` projection the planning contract names authoritative, and gating
  that writer on viewers would change *when a file on disk is written* — a
  different risk class, kept out of this change. See its moduledoc.

  Because the demander set lives in each source's GenServer, a supervisor
  restart empties it while the pages watching that source are still open. Every
  tick therefore asks each running source to re-seed its demanders from its
  PubSub subscriber presence before deciding whether to reconcile it, so a
  crash cannot silently strand an open page — recovery just returns on the next
  tick, as it did before the gate existed.

  ## What this is not, yet

  Stated plainly because the gap is easy to mistake for a bug: the three sources
  below do **not** yet read the store, subscribe to its change events, or get
  woken by a webhook delivery. Each still performs its own listing when asked.
  So today this sweep is not merely closing a gap left by free writers — for
  these three it is the only thing that refreshes them at all, and a change made
  outside Aiur surfaces within one sweep interval rather than immediately.

  That is the deliberate order of work: this module removes the cost, and the
  store subscription that removes the latency — a subscribed view re-rendering
  the instant any writer deposits — lands with the units that make these sources
  read the store. The interval is sized for that, not for freshness.

  ## What it replaced

  Three view-state sources each ran their own timer against GitHub, none of them
  with a config key an operator could reach:

    * `Aiur.OpenTicketSource` — the whole open backlog, every 120s
    * `Aiur.BuildOrder.AdHocSource` — a labelled issue listing, every 60s
    * `Aiur.BuildOrder.PackStatus` — a GraphQL pack read, every 300s

  Three independent cadences against one API, at three intervals nobody chose
  together, is how the burn this ticket exists to remove was built. Measured
  against GitHub's own `rateLimit { cost }`, each of those reads costs one point,
  so the three together were 1.7 requests per minute for state nobody was
  necessarily looking at. They now hold no timer at all: this process ticks and
  asks each of them to reconcile only while it is demanded, and each one still
  refreshes on demand through its own `refresh/1`.

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
      sources: Keyword.get(opts, :sources, @sources),
      timer: nil
    }

    if Keyword.get(opts, :sweep_on_start, false), do: send(self(), :sweep)
    {:ok, schedule(state)}
  end

  @impl true
  def handle_call(:sweep_now, _from, state), do: {:reply, sweep(state), state}
  def handle_call(:interval_ms, _from, state), do: {:reply, state.interval, state}
  def handle_call(:timer, _from, state), do: {:reply, state.timer, state}

  @impl true
  def handle_info(:sweep, state) do
    sweep(state)
    {:noreply, schedule(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A source is refreshed only while it reports demanded, and a source that is
  # not running is skipped rather than started: the sweep is recovery for state
  # somebody is holding, and there is nothing to recover for a source this
  # deployment does not run at all. With no demander the two view-only sources
  # are skipped too — the recovery is for a page that is open, and an idle
  # daemon with no dashboard session open costs them nothing. `PackStatus` is
  # the exception: it answers demanded unconditionally, so it is reconciled on
  # every tick regardless of viewers (see its moduledoc).
  #
  # Every running source is asked to re-seed demand first. A source's demander
  # set lives in its own GenServer, so a supervisor restart empties it while
  # the pages that watch it are still alive and still subscribed to its PubSub
  # topic; re-seeding from subscriber presence restores the demand and, with
  # it, the reconcile. Without it a single crash would convert the demand gate
  # into permanent silence for every open page — the exact self-healing the
  # unconditional pre-gate sweep used to provide (review finding 3).
  defp sweep(state) do
    Enum.filter(state.sources, fn source ->
      if Process.whereis(source) do
        source.reseed_demand()
        refresh_if_demanded(source)
      else
        false
      end
    end)
  end

  # Kept out of `sweep/1` so the per-source decision stays within Credo's
  # nesting ceiling; the demand gate is the single `if` that decides whether
  # the sweep reconciles a running source this tick.
  defp refresh_if_demanded(source) do
    if source.demanded?() do
      source.refresh()
      true
    else
      false
    end
  end

  # Arming cancels first, so this process holds **at most one** timer no matter
  # how many paths reach it. That matters more than it looks: a boot that both
  # sent an immediate sweep and armed a delayed one would leave two permanent
  # timers, silently doubling the sweep rate and its cost, in the module whose
  # entire premise is that there is one. Holding the reference makes "one timer"
  # a property of the state rather than of every caller remembering.
  defp schedule(%{interval: interval} = state) when is_integer(interval) and interval > 0 do
    if is_reference(state.timer), do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :sweep, interval)}
  end

  defp schedule(state), do: %{state | timer: nil}

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

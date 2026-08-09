defmodule Aiur.ProviderMeterRefresh do
  @moduledoc """
  Decides *when* provider usage is observed.

  Observations otherwise only arrive as a side effect of agent sessions, so a
  daemon that has not run anything yet has nothing to show, and a fleet that
  has gone quiet shows values that silently stop moving.

  Three rules, all deliberate:

  - **Only while watched.** Polling exists to keep a surface current, so it runs
    only while a surface is actually in focus, plus a grace period after the
    last watcher looks away. An abandoned tab stops costing requests; a glance
    elsewhere does not cost a stale meter on return. A surface gaining focus is
    observed immediately rather than waiting out the interval.
  - **One baseline shortly after boot**, so the first surface to open shows real
    values rather than "not observed".
  - **Codex only while agents run.** Observing Codex means opening an app-server
    session, and a fleet consuming nothing cannot have moved its own usage.
    Claude is a cached HTTPS read of the account usage endpoint, so it refreshes
    whenever anyone is looking.

  The observer and clock are injected. This module owns cadence and gating only.
  """

  use GenServer

  alias Aiur.Config
  alias Aiur.ProviderMeterProbe

  # Matches polling.usage_interval_seconds's measured 300s default: the
  # provider usage endpoint allows roughly one request per two minutes.
  @default_interval_ms 300_000
  # Long enough after boot that the providers' own supervision tree is up,
  # short enough that an operator opening a surface early still sees values.
  @default_baseline_delay_ms 5_000
  # How long polling continues after the last watcher looks away.
  @default_grace_ms 5 * 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker, restart: :permanent, shutdown: 5_000}
  end

  @doc "Observe now, regardless of cadence or agent activity."
  @spec refresh_now(GenServer.server()) :: :ok
  def refresh_now(server \\ __MODULE__), do: GenServer.cast(server, :observe)

  @doc """
  Register the calling process as a watcher with the dashboard in focus.

  Polling exists to keep a surface current, so it runs only while a surface is
  actually being looked at. The watcher is monitored: a closed tab or a crashed
  LiveView withdraws itself without needing a matching `watching_stopped/1`.
  """
  @spec watching_started(GenServer.server()) :: :ok
  def watching_started(server \\ __MODULE__), do: GenServer.cast(server, {:watching_started, self()})

  @doc """
  Withdraw the calling process as a focused watcher.

  Polling continues for a grace period afterwards rather than stopping dead, so
  glancing away and back does not cost a stale meter.
  """
  @spec watching_stopped(GenServer.server()) :: :ok
  def watching_stopped(server \\ __MODULE__), do: GenServer.cast(server, {:watching_stopped, self()})

  @impl true
  def init(opts) do
    state = %{
      observer: Keyword.get(opts, :observer, &ProviderMeterProbe.observe/1),
      agents_running?: Keyword.get(opts, :agents_running_fun, &agents_running?/0),
      interval_fun: Keyword.get(opts, :interval_fun, &configured_interval_ms/0),
      now_fun: Keyword.get(opts, :now_fun, &System.monotonic_time/0),
      grace_ms: Keyword.get(opts, :grace_ms, @default_grace_ms),
      # Monitored pids of LiveViews currently focused on a surface that shows
      # meters, and when the last of them looked away.
      watchers: %{},
      last_watched_at: nil,
      baseline_done?: false,
      probe_ref: nil
    }

    baseline_delay = Keyword.get(opts, :baseline_delay_ms, @default_baseline_delay_ms)
    if baseline_delay != :never, do: Process.send_after(self(), :baseline, baseline_delay)

    # The tick loop runs independently of the baseline: it must keep ticking
    # even when the baseline is disabled, because whether a tick *observes* is
    # the `watched?` gate's decision, not the scheduler's. Starting the loop
    # inside the baseline handler meant a caller that opted out of the baseline
    # got no loop at all.
    schedule_refresh(state)

    {:ok, state}
  end

  @impl true
  def handle_info(:baseline, state) do
    # Runs once regardless of watchers or agent activity, so the first surface
    # to open finds real values already there. The tick loop is scheduled in
    # init/1, so this must not schedule another or the two would compound.
    state = observe(state)

    {:noreply, %{state | baseline_done?: true}}
  end

  def handle_info(:refresh, state) do
    state = if watched?(state), do: observe(state, refresh_target(state)), else: state
    schedule_refresh(state)

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{probe_ref: ref} = state) do
    {:noreply, %{state | probe_ref: nil}}
  end

  # A watcher that closed its tab or crashed stops being one, without needing a
  # tidy goodbye it may never get to send.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop_watcher(state, pid)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast(:observe, state) do
    {:noreply, observe(state)}
  end

  def handle_cast({:watching_started, pid}, state) do
    state =
      if Map.has_key?(state.watchers, pid) do
        state
      else
        %{state | watchers: Map.put(state.watchers, pid, Process.monitor(pid))}
      end

    # Someone just looked: answer immediately rather than making them wait out
    # the interval for a number that is already stale.
    {:noreply, observe(state, refresh_target(state))}
  end

  def handle_cast({:watching_stopped, pid}, state), do: {:noreply, drop_watcher(state, pid)}

  defp drop_watcher(state, pid) do
    case Map.pop(state.watchers, pid) do
      {nil, _watchers} ->
        state

      {ref, watchers} ->
        Process.demonitor(ref, [:flush])
        # Stamp the moment the last watcher left; the grace period runs from
        # there.
        last_watched_at = if map_size(watchers) == 0, do: state.now_fun.(), else: state.last_watched_at
        %{state | watchers: watchers, last_watched_at: last_watched_at}
    end
  end

  # Poll while someone is watching, and for a grace period after the last one
  # looks away — a glance elsewhere should not cost a stale meter on return,
  # but an abandoned tab should stop costing requests.
  defp watched?(%{watchers: watchers}) when map_size(watchers) > 0, do: true
  defp watched?(%{last_watched_at: nil}), do: false

  defp watched?(state) do
    elapsed_ms = System.convert_time_unit(state.now_fun.() - state.last_watched_at, :native, :millisecond)
    elapsed_ms < state.grace_ms
  end

  # Both providers refresh on every tick now that ticks only happen while
  # someone is watching. Codex costs more than Claude — it opens a short
  # app-server session rather than making an HTTP call — but an operator looking
  # at a meter wants both numbers, and the watch gate already bounds how often
  # that cost is paid. `agents_running?` is retained: it is still the honest
  # answer to "is this fleet consuming anything", and callers inject it.
  defp refresh_target(_state), do: :all

  # An observer failure must never take the scheduler down: a provider being
  # unreachable is an expected condition, and the retained observation keeps
  # displaying with its true age.
  defp observe(state, target \\ :all)

  defp observe(%{probe_ref: ref} = state, _target) when is_reference(ref), do: state

  defp observe(state, target) do
    case Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> safe_observe(state.observer, target) end) do
      {:ok, pid} -> %{state | probe_ref: Process.monitor(pid)}
      {:error, _reason} -> state
    end
  end

  defp safe_observe(observer, target) do
    _ = observer.(target)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp schedule_refresh(state), do: Process.send_after(self(), :refresh, state.interval_fun.())

  defp configured_interval_ms do
    case Config.settings() do
      {:ok, %{polling: %{usage_interval_seconds: seconds}}} when is_integer(seconds) and seconds > 0 ->
        seconds * 1_000

      _unset_or_unavailable ->
        @default_interval_ms
    end
  rescue
    _error -> @default_interval_ms
  catch
    _kind, _reason -> @default_interval_ms
  end

  defp agents_running? do
    case Aiur.Orchestrator.snapshot(Aiur.Orchestrator, 5_000) do
      %{running: running} when is_list(running) -> running != []
      _other -> false
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end
end

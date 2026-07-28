defmodule Aiur.ProviderMeterRefresh do
  @moduledoc """
  Decides *when* provider usage is observed.

  Observations otherwise only arrive as a side effect of agent sessions, so a
  daemon that has not run anything yet has nothing to show, and a fleet that
  has gone quiet shows values that silently stop moving.

  Two rules, both deliberate:

  - One baseline observation shortly after boot, so a surface opened before any
    agent runs shows real values rather than "not observed".
  - Afterwards, re-observe only while at least one agent is running. Observing
    costs a provider session, and a fleet consuming nothing cannot have moved
    its own usage. The retained observation keeps displaying with its age, so
    an idle fleet is honest rather than blank.

  The observer itself is injected. This module owns cadence and gating only.
  """

  use GenServer

  alias Aiur.Config
  alias Aiur.ProviderMeterProbe

  @default_interval_ms 60_000
  # Long enough after boot that the providers' own supervision tree is up,
  # short enough that an operator opening a surface early still sees values.
  @default_baseline_delay_ms 5_000

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

  @impl true
  def init(opts) do
    state = %{
      observer: Keyword.get(opts, :observer, &ProviderMeterProbe.observe/1),
      agents_running?: Keyword.get(opts, :agents_running_fun, &agents_running?/0),
      interval_fun: Keyword.get(opts, :interval_fun, &configured_interval_ms/0),
      baseline_done?: false
    }

    baseline_delay = Keyword.get(opts, :baseline_delay_ms, @default_baseline_delay_ms)
    if baseline_delay != :never, do: Process.send_after(self(), :baseline, baseline_delay)

    {:ok, state}
  end

  @impl true
  def handle_info(:baseline, state) do
    # The baseline runs once regardless of agent activity — that is the whole
    # point of it, and the "only while agents run" rule governs refreshes after.
    observe(state)
    schedule_refresh(state)

    {:noreply, %{state | baseline_done?: true}}
  end

  def handle_info(:refresh, state) do
    if state.agents_running?.(), do: observe(state)
    schedule_refresh(state)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast(:observe, state) do
    observe(state)
    {:noreply, state}
  end

  # An observer failure must never take the scheduler down: a provider being
  # unreachable is an expected condition, and the retained observation keeps
  # displaying with its true age.
  defp observe(state) do
    _ = state.observer.(:all)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp schedule_refresh(state), do: Process.send_after(self(), :refresh, state.interval_fun.())

  defp configured_interval_ms do
    case Config.settings() do
      %{polling: %{usage_interval_seconds: seconds}} when is_integer(seconds) and seconds > 0 -> seconds * 1_000
      _other -> @default_interval_ms
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

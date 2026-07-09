defmodule Aiur.PeriodicWorker do
  @moduledoc """
  Shared skeleton for self-rescheduling periodic GenServers (pollers and
  tickers) — the periodic-tick frame from dup-infra.md cluster 1.

  `use Aiur.PeriodicWorker` injects:

    * `start_link/1` honoring a `:name` option (default: the using
      module); overridable,
    * `handle_info(:tick, state)` that runs the module's `c:tick/1`
      inside mandatory crash isolation (a crashed tick can never
      silently stop the schedule), then re-schedules using the returned
      state's `:next_delay_ms` when present, else `:interval_ms`,
    * a catch-all `handle_info(_other, state)`.

  The using module keeps its own `init/1` (module-specific state). Its
  state map MUST contain `:interval_ms` (positive integer) and
  `:start_paused?` (boolean; when `true` the first tick is not
  scheduled — tests drive `:tick` manually), and `init/1` must end with
  `{:ok, Aiur.PeriodicWorker.schedule_first_tick(state)}`.
  """

  require Logger

  @doc """
  Runs one poll/sweep cycle. Receives the current state and returns the
  updated state. A returned `:next_delay_ms` key sets the delay before
  the next tick; otherwise `:interval_ms` is used. Raises and throws are
  caught by `run_tick/2` — the previous state is kept and the schedule
  survives.
  """
  @callback tick(state :: map()) :: map()

  defmacro __using__(_opts) do
    quote location: :keep do
      use GenServer

      @behaviour Aiur.PeriodicWorker

      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts \\ []) do
        name = Keyword.get(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, opts, name: name)
      end

      @impl GenServer
      def handle_info(:tick, state) do
        state = Aiur.PeriodicWorker.run_tick(__MODULE__, state)

        Aiur.PeriodicWorker.schedule_tick(Map.get(state, :next_delay_ms, state.interval_ms))

        {:noreply, state}
      end

      @impl GenServer
      def handle_info(_other, state), do: {:noreply, state}

      defoverridable start_link: 1
    end
  end

  @doc """
  Invokes `module.tick(state)` under the mandatory rescue/catch. On a
  raise or throw the error is logged as a warning and the previous
  state is returned unchanged, so the caller still re-schedules.
  """
  @spec run_tick(module(), map()) :: map()
  def run_tick(module, state) do
    module.tick(state)
  rescue
    error ->
      Logger.warning("#{worker_label(module)} tick raised: #{Exception.message(error)} (#{inspect(error.__struct__)})")

      state
  catch
    kind, reason ->
      Logger.warning("#{worker_label(module)} tick caught #{kind}: #{inspect(reason)}")
      state
  end

  @doc "Schedules the next `:tick` message to the calling process."
  @spec schedule_tick(pos_integer()) :: reference()
  def schedule_tick(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :tick, interval_ms)
  end

  @doc """
  Schedules the first tick unless `state.start_paused?` is true.
  Returns the state unchanged so `init/1` can end with
  `{:ok, schedule_first_tick(state)}`.
  """
  @spec schedule_first_tick(map()) :: map()
  def schedule_first_tick(state) do
    unless state.start_paused?, do: schedule_tick(state.interval_ms)
    state
  end

  defp worker_label(module), do: module |> Module.split() |> List.last()
end

defmodule Aiur.DaemonHeartbeatWriter do
  @moduledoc """
  Periodic worker that refreshes the daemon heartbeat file every 5 minutes.

  The heartbeat file signals daemon liveness to the Executor. An initial write
  occurs at boot (via `Aiur.DaemonHeartbeat.write!/0`), and this worker
  refreshes it on a 5-minute interval to keep it current.

  Failures are best-effort: a tick failure is logged by the PeriodicWorker
  infrastructure and the schedule continues. The previous heartbeat timestamp
  remains valid if a refresh fails, so liveness detection remains sound.
  """

  use Aiur.PeriodicWorker

  require Logger

  # 5 minutes
  @default_interval_ms 300_000

  @doc """
  Start the heartbeat writer.

  Accepts:
    * `:interval_ms` — tick period in milliseconds (default 5 minutes).
    * `:start_paused?` — when `true`, the first tick is not scheduled.
      Tests drive `:tick` manually.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      start_paused?: Keyword.get(opts, :start_paused?, false)
    }

    {:ok, Aiur.PeriodicWorker.schedule_first_tick(state)}
  end

  @impl Aiur.PeriodicWorker
  @spec tick(map()) :: map()
  def tick(state) do
    Aiur.DaemonHeartbeat.write!()
    state
  end
end

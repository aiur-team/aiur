defmodule Aiur.Orchestrator.SnapshotPublisher do
  @moduledoc """
  Owns the dashboard snapshot publish cadence independently of the Orchestrator
  mailbox.

  The Orchestrator GenServer also handles dispatch, so publishing fleet
  snapshots from inside it let sustained dispatch starve the dashboard cadence
  (#1549). This process owns a shared ETS write-model: the Orchestrator writes
  its latest bounded snapshot input here (fire-and-forget), and this process
  periodically casts any *new* input to `SnapshotStore` for projection.

  An input is republished only when its version actually changes, so a
  genuinely stalled Orchestrator (no new writes) is not masked by a heartbeat:
  its snapshot still ages and `SnapshotStore.read/2` flags it `:stale`.
  """

  use GenServer

  alias Aiur.Orchestrator.SnapshotStore

  @table __MODULE__
  @table_opts [
    :named_table,
    :public,
    :set,
    read_concurrency: true,
    write_concurrency: true
  ]
  @default_publish_interval_ms 250

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records the latest bounded snapshot input for an orchestrator.

  Fire-and-forget: the Orchestrator never blocks on the publish cadence, so
  dispatch load in its mailbox cannot starve the dashboard update. The version
  is monotonic per write; the publisher republishes only versions it has not
  already cast to `SnapshotStore`. When the publisher is not running (e.g.
  module-level tests without the booted app), the write is a safe no-op.
  """
  @spec write(GenServer.server(), reference() | nil, map()) :: :ok
  def write(orchestrator, generation, snapshot_input) when is_map(snapshot_input) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _table ->
        version = System.unique_integer([:monotonic, :positive])
        :ets.insert(@table, {orchestrator, generation, version, snapshot_input})
        :ok
    end
  end

  @doc """
  Drops any stale write-model entry for an orchestrator.

  Called when a new snapshot generation begins (an Orchestrator restart with
  the same registered name) so the publisher never casts the prior instance's
  fenced input.
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(orchestrator) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _table -> :ets.delete(@table, orchestrator)
    end

    :ok
  end

  @impl true
  def init(_opts) do
    ensure_table()
    schedule_publish()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:publish, published) do
    published = publish_pending(published)
    schedule_publish()
    {:noreply, published}
  end

  def handle_info(_message, published), do: {:noreply, published}

  defp publish_pending(published) do
    :ets.tab2list(@table)
    |> Enum.reduce(published, fn {orchestrator, generation, version, snapshot_input}, acc ->
      case Map.get(acc, orchestrator) do
        {^generation, ^version} ->
          acc

        _unpublished_version ->
          SnapshotStore.publish_state(orchestrator, generation, snapshot_input)
          Map.put(acc, orchestrator, {generation, version})
      end
    end)
  end

  defp schedule_publish do
    Process.send_after(self(), :publish, publish_interval_ms())
  end

  defp publish_interval_ms do
    Application.get_env(:aiur, :snapshot_publish_interval_ms, @default_publish_interval_ms)
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, @table_opts)
      table -> table
    end
  end
end

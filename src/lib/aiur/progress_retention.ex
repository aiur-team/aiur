defmodule Aiur.ProgressRetention do
  @moduledoc """
  Durable last-known progress readings per ticket.

  `Aiur.TicketActivity.Projection` retains the latest progress reading in
  memory, but that projection dies with its process: after a projection or
  daemon restart every ticket that already reported re-entered `unknown` until
  the next agent emission, which on a quiet fleet can be a long time (#1963).
  This store is the durable "has reported progress" memory — a file-backed
  checkpoint that survives restarts and is re-seeded into the projection at
  boot, so `unknown` means only "this ticket has never reported".

  ## Semantics

  A reading is retained until superseded by a newer one: latest-`order`-wins,
  using the same `{observed_at, event_id}` ordering the projection uses, so
  out-of-order casts (a late observation re-applied after a restart) never roll
  a reading back. The store keeps the projection's raw progress value
  (`percent`, `source`, `provenance`, `occurred_at`, `observed_at`, `event_id`,
  `order`), which lets every consumer recompute freshness honestly from
  `observed_at`.

  The store never decides `:fresh` versus `:stale` — that is the projection's
  job. It is also deliberately not a journal: the checkpoint is a cache of
  last-known values that is safe to lose and cheap to rebuild, so persistence
  is best-effort (debounced write, synchronous `flush/1`, final `terminate`
  write) and a failure degrades health without taking the fleet view down.

  ## Concurrency

  Writes are serialized through this GenServer. Reads (`all/1`) hit a
  `:read_concurrency` ETS mirror instead of the mailbox, so
  `Aiur.Orchestrator.StatusReport` can consult retained progress on every
  snapshot without queueing behind the store.
  """

  use GenServer

  require Logger

  alias Aiur.{Config, TrackerIdentity}
  alias Aiur.ProgressRetention.Checkpoint

  @checkpoint_filename "checkpoint.json"
  @debounce_ms 2_000

  @type retained_entry :: %{identity: TrackerIdentity.t(), progress: map()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Retains the latest progress reading for `identity`.

  Latest-`order`-wins: a value whose progress `order` is older than or equal to
  the current reading for the same identity is a no-op. `progress` is the
  projection's raw progress value (`percent`, `source`, `provenance`,
  `occurred_at`, `observed_at`, `event_id`, `order`). Best-effort and
  fire-and-forget: the caller (a projection process) never blocks on the
  durable write.
  """
  @spec retain(TrackerIdentity.t(), map(), keyword()) :: :ok
  def retain(%TrackerIdentity{} = identity, %{percent: percent} = progress, opts \\ [])
      when is_integer(percent) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.cast(server, {:retain, identity, progress})
    :ok
  end

  @doc """
  All retained readings, keyed by `TrackerIdentity.github_key/1`.

  Served from the store's ETS mirror so it is lock-free and never queues behind
  the store's mailbox. Returns `%{}` when the store is not running (tests,
  pre-boot), so callers never handle a missing store specially.
  """
  @spec all(keyword()) :: map()
  def all(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    if match?(name when is_atom(name) and not is_nil(name), server) and Process.whereis(server) do
      read_mirror(mirror_table(server))
    else
      retained_via_call(server)
    end
  end

  @doc """
  Synchronously persists any unflushed readings to disk.

  Returns `:ok` even when there is nothing to persist or no durable
  destination; returns `{:error, reason}` only when a real write failed.
  """
  @spec flush(keyword()) :: :ok | {:error, term()}
  def flush(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :flush)
  end

  @doc false
  @spec health(GenServer.server()) :: term()
  def health(server \\ __MODULE__), do: GenServer.call(server, :health)

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    table = mirror_table(name)
    :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    :ets.insert(table, {:all, %{}})

    case resolve_state_dir(Keyword.get(opts, :state_dir)) do
      {:ok, dir} ->
        :ok = File.mkdir_p(dir)
        path = Path.join(dir, @checkpoint_filename)
        {retained, health} = Checkpoint.load(path)
        :ets.insert(table, {:all, retained})

        {:ok,
         %{
           table: table,
           retained: retained,
           health: health,
           dirty?: false,
           flush_timer: nil,
           path: path,
           synced?: false
         }}

      {:error, reason} ->
        {:ok,
         %{
           table: table,
           retained: %{},
           health: {:degraded, {:state_dir_unavailable, reason}},
           dirty?: false,
           flush_timer: nil,
           path: nil,
           synced?: false
         }}
    end
  end

  @impl true
  def handle_cast({:retain, identity, progress}, state) do
    {:noreply, handle_retain(state, identity, progress)}
  end

  @impl true
  def handle_call(:all, _from, state), do: {:reply, state.retained, state}
  def handle_call(:health, _from, state), do: {:reply, state.health, state}

  def handle_call(:flush, _from, state) do
    case do_flush(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    state = %{state | flush_timer: nil}
    {:noreply, flush_result_state(do_flush(state))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    case do_flush(state) do
      {:ok, _state} ->
        :ok

      {:error, reason, _state} ->
        Logger.warning("aiur_progress_retention terminate_flush_failed reason=#{inspect(reason)}")
        :ok
    end
  end

  defp handle_retain(state, identity, progress) do
    key = TrackerIdentity.github_key(identity)

    if is_nil(key) or not is_map(progress) do
      state
    else
      retain_latest_reading(state, key, identity, progress)
    end
  end

  defp retain_latest_reading(state, key, identity, progress) do
    case Map.get(state.retained, key) do
      %{progress: %{order: existing_order}} when is_tuple(existing_order) ->
        if newer_order?(progress, existing_order), do: put_retained(state, key, identity, progress), else: state

      _ ->
        put_retained(state, key, identity, progress)
    end
  end

  defp put_retained(state, key, identity, progress) do
    retained = Map.put(state.retained, key, %{identity: identity, progress: progress})
    :ets.insert(state.table, {:all, retained})
    state = %{state | retained: retained, dirty?: true}
    schedule_flush(state)
  end

  defp newer_order?(%{order: order}, existing_order) when is_tuple(order), do: order > existing_order
  defp newer_order?(_progress, _existing_order), do: true

  defp schedule_flush(%{flush_timer: nil} = state) do
    %{state | flush_timer: Process.send_after(self(), :flush, @debounce_ms)}
  end

  defp schedule_flush(state), do: state

  defp flush_result_state({:ok, state}), do: state
  defp flush_result_state({:error, _reason, state}), do: state

  defp do_flush(%{dirty?: false} = state), do: {:ok, state}
  defp do_flush(%{path: nil} = state), do: {:ok, %{state | dirty?: false}}

  defp do_flush(state) do
    case Checkpoint.write(state.path, state.retained, not state.synced?) do
      :ok ->
        {:ok, %{state | dirty?: false, synced?: true}}

      {:error, reason} ->
        {:error, reason, %{state | health: {:degraded, {:flush_failed, reason}}}}
    end
  end

  defp resolve_state_dir(dir) when is_binary(dir) and dir != "", do: {:ok, dir}
  defp resolve_state_dir(_dir), do: Config.Paths.progress_retention_state_dir()

  defp mirror_table(name) when is_atom(name) and not is_nil(name),
    do: :"#{inspect(name)}.ProgressRetention.Mirror"

  defp mirror_table(_name),
    do: :"Aiur.ProgressRetention.Mirror.#{System.unique_integer([:positive])}"

  defp read_mirror(table) do
    case :ets.lookup(table, :all) do
      [{:all, retained}] -> retained
      [] -> %{}
    end
  rescue
    _ -> %{}
  end

  defp retained_via_call(server) when is_pid(server) do
    if Process.alive?(server), do: GenServer.call(server, :all), else: %{}
  end

  defp retained_via_call(server) do
    if Process.whereis(server), do: GenServer.call(server, :all), else: %{}
  end
end

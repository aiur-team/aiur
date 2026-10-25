defmodule Aiur.RunTelemetry.RetainedCache do
  @moduledoc "Bounded retained projections with one cold loader independent of request lifetime."
  use GenServer

  alias Aiur.RunTelemetry.Summaries

  @identity_table Aiur.RunTelemetry.RetainedCache.Identity

  @doc "Shares a cold load; failures are propagated to every waiter and never cached."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    result = if is_nil(name), do: GenServer.start_link(__MODULE__, opts), else: GenServer.start_link(__MODULE__, opts, name: name)

    case result do
      {:ok, pid} ->
        warm_identity_async()
        {:ok, pid}

      error ->
        error
    end
  end

  @doc "Shares a cold load; failures are propagated to every waiter and never cached."
  @spec fetch(atom(), term(), (-> term()), keyword()) :: term()
  def fetch(table, key, loader, opts \\ []) do
    ensure_started()

    case GenServer.call(__MODULE__, {:fetch, table, key, loader, opts}, :infinity) do
      {:value, value} -> value
      {:raised, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
    end
  end

  @doc false
  @spec lookup(atom(), term()) :: term() | nil
  def lookup(table, key) do
    ensure_started()
    GenServer.call(__MODULE__, {:lookup, table, key})
  end

  @doc false
  @spec put(atom(), term(), term(), keyword()) :: :ok
  def put(table, key, value, opts \\ []) do
    ensure_started()
    GenServer.call(__MODULE__, {:put, table, key, value, opts})
  end

  @doc "Identity of retained summary files, excluding the current boot."
  @spec identity(String.t() | nil) :: term()
  def identity(current_boot) do
    {Summaries.state_node(), current_boot, cached_identity(current_boot)}
  end

  @doc false
  @spec invalidate_identity() :: :ok
  def invalidate_identity do
    ensure_started()
    GenServer.call(__MODULE__, :invalidate_identity, :infinity)
    :ok
  end

  @doc false
  @spec invalidate_identity(pid()) :: :ok
  def invalidate_identity(notify) when is_pid(notify) do
    ensure_started()
    GenServer.call(__MODULE__, {:invalidate_identity, notify}, :infinity)
    :ok
  end

  @doc false
  @spec warm_identity_async() :: :ok
  def warm_identity_async do
    Task.start(fn -> warm_identity() end)
    :ok
  end

  @doc false
  @spec warm_identity_async(pid()) :: :ok
  def warm_identity_async(notify) when is_pid(notify) do
    Task.start(fn ->
      warm_identity()
      send(notify, :retained_identity_warmed)
    end)

    :ok
  end

  @doc false
  @spec warm_identity() :: term()
  def warm_identity do
    ensure_table(@identity_table)
    current = Aiur.RunTelemetry.boot_id()
    cached_identity(current)
  rescue
    _error -> :error
  end

  defp cached_identity(current_boot) do
    key = {Summaries.state_node(), current_boot}
    ensure_started()
    GenServer.call(__MODULE__, {:identity, key, current_boot}, :infinity)
  end

  @doc false
  @spec summaries_identity(String.t() | nil) :: [{String.t(), tuple()}]
  def summaries_identity(current_boot) do
    Summaries.summary_boot_ids()
    |> Enum.reject(&(&1 == current_boot))
    |> Enum.map(fn boot -> {boot, file_identity(Summaries.run_summary_path(boot))} end)
  end

  @doc false
  @spec file_identity(Path.t()) :: tuple()
  def file_identity(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {stat.inode, stat.size, stat.mtime, stat.ctime}
      {:error, reason} -> {reason}
    end
  end

  defp summary_directories_identity(current_boot) do
    boots = Summaries.summary_boot_ids() |> Enum.reject(&(&1 == current_boot))

    {boots,
     Enum.map(boots, fn boot ->
       path = Summaries.run_summary_path(boot) |> Path.dirname()
       {boot, file_identity(path), file_identity(Summaries.run_summary_path(boot))}
     end)}
  end

  defp ensure_started do
    case GenServer.start(__MODULE__, nil, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @impl true
  def init(_arg) do
    ensure_table(@identity_table)
    {:ok, %{active: nil, pending: %{}, queue: :queue.new()}}
  end

  @impl true
  def handle_call({:fetch, table, key, loader, opts}, from, state) do
    ensure_table(table)

    case :ets.lookup(table, key) do
      [{^key, value}] ->
        {:reply, {:value, value}, state}

      [] ->
        id = {table, key}
        existing = Map.has_key?(state.pending, id)
        job = %{loader: loader, opts: opts, waiters: [from]}
        pending = Map.update(state.pending, id, job, &%{&1 | waiters: [from | &1.waiters]})
        queue = if existing, do: state.queue, else: :queue.in(id, state.queue)
        {:noreply, start_next(%{state | pending: pending, queue: queue})}
    end
  end

  def handle_call({:lookup, table, key}, _from, state) do
    ensure_table(table)

    value =
      case :ets.lookup(table, key) do
        [{^key, value}] -> value
        [] -> nil
      end

    {:reply, value, state}
  end

  def handle_call({:put, table, key, value, opts}, _from, state) do
    ensure_table(table)
    cache_put(table, key, value, opts)
    {:reply, :ok, state}
  end

  def handle_call({:identity, key, current_boot}, _from, state) do
    directory_identity = summary_directories_identity(current_boot)

    case :ets.lookup(@identity_table, key) do
      [{^key, {^directory_identity, identity}}] ->
        {:reply, identity, state}

      [] ->
        identity = summaries_identity(current_boot)
        :ets.insert(@identity_table, {key, {directory_identity, identity}})
        {:reply, identity, state}

      [{^key, _stale}] ->
        identity = summaries_identity(current_boot)
        :ets.insert(@identity_table, {key, {directory_identity, identity}})
        {:reply, identity, state}
    end
  end

  def handle_call(:invalidate_identity, _from, state) do
    :ets.delete_all_objects(@identity_table)
    warm_identity_async()
    {:reply, :ok, state}
  end

  def handle_call({:invalidate_identity, notify}, _from, state) do
    :ets.delete_all_objects(@identity_table)
    warm_identity_async(notify)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:loaded, pid, result}, %{active: {pid, monitor, id}} = state) do
    Process.demonitor(monitor, [:flush])
    {job, pending} = Map.pop!(state.pending, id)
    {table, key} = id
    if cacheable?(result), do: cache_put(table, key, elem(result, 1), job.opts)
    Enum.each(job.waiters, &GenServer.reply(&1, result))
    {:noreply, start_next(%{state | active: nil, pending: pending})}
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, %{active: {pid, monitor, _id}} = state) do
    handle_info({:loaded, pid, {:raised, :exit, reason, []}}, state)
  end

  defp start_next(%{active: nil} = state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, id}, queue} ->
        owner = self()
        loader = state.pending[id].loader

        {pid, monitor} =
          spawn_monitor(fn ->
            result =
              try do
                {:value, loader.()}
              catch
                kind, reason -> {:raised, kind, reason, __STACKTRACE__}
              end

            send(owner, {:loaded, self(), result})
          end)

        %{state | active: {pid, monitor, id}, queue: queue}
    end
  end

  defp start_next(state), do: state

  defp cacheable?({:value, {:error, _reason}}), do: false
  defp cacheable?({:value, {[], true}}), do: false
  defp cacheable?({:value, _value}), do: true
  defp cacheable?(_result), do: false

  defp cache_put(table, key, value, opts) do
    size = :erlang.external_size(value)
    max_value = min(Keyword.get(opts, :max_value_bytes, 2 * 1024 * 1024), 24 * 1024 * 1024)

    if size <= max_value do
      bytes = :ets.foldl(fn {_key, stored}, total -> total + :erlang.external_size(stored) end, 0, table)
      max_entries = min(Keyword.get(opts, :max_entries, 8), 64)
      if :ets.info(table, :size) >= max_entries or bytes + size > 24 * 1024 * 1024, do: :ets.delete_all_objects(table)
      :ets.insert(table, {key, value})
    end
  end

  defp ensure_table(table) do
    if :ets.whereis(table) == :undefined, do: :ets.new(table, [:named_table, :protected, :set])
  end
end

defmodule Aiur.RunTelemetry.RetainedCache do
  @moduledoc "Bounded retained projections with one cold loader independent of request lifetime."
  use GenServer

  alias Aiur.RunTelemetry.Summaries

  @doc "Shares a cold load; failures are propagated to every waiter and never cached."
  @spec fetch(atom(), term(), (-> term()), keyword()) :: term()
  def fetch(table, key, loader, opts \\ []) do
    ensure_started()

    case GenServer.call(__MODULE__, {:fetch, table, key, loader, opts}, :infinity) do
      {:value, value} -> value
      {:raised, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
    end
  end

  @doc "Identity of retained summary files, excluding the current boot."
  @spec identity(String.t() | nil) :: term()
  def identity(current_boot) do
    {Summaries.state_node(), current_boot, summaries_identity(current_boot)}
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

  defp ensure_started do
    case GenServer.start(__MODULE__, nil, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @impl true
  def init(_arg), do: {:ok, %{active: nil, pending: %{}, queue: :queue.new()}}

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

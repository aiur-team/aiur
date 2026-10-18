defmodule AiurWeb.Build.Index do
  @moduledoc "One async, coalescing build-home index per dashboard daemon."
  use GenServer
  alias Aiur.BuildOrder.Index, as: Core
  alias AiurWeb.Build.{Freshness, HistoryCarry, IndexReader}
  require Logger
  @window 250
  @signals %{
    build_order_history_changed: ~w(history health catch_up planned not_queued)a,
    build_order_features_changed: [:features],
    epic_overrides_changed: [:overrides],
    build_progress_changed: ~w(queue planned not_queued)a,
    build_queue_changed: ~w(queue planned not_queued)a,
    open_tickets_updated: ~w(open planned not_queued)a,
    ticket_activity_changed: ~w(now planned not_queued)a,
    running_changed: ~w(now planned not_queued)a
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Cuts one mount's window in the caller, so concurrent mounts never queue behind the server's sort and page work."
  @spec window(GenServer.server(), String.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def window(server, zone, timeout \\ 5_000) do
    {:ok, table, now} = GenServer.call(server, :table, timeout)

    with {:ok, generation, index, daemon} <- read_table(table),
         {:ok, base} <- index,
         do: {:ok, base |> Core.window(zone, now) |> Map.merge(%{index_generation: generation, daemon: daemon})}
  end

  # Only the table reads mean a dead index; a fault in the cut itself must propagate.
  defp read_table(table) do
    # Generation is published after its data, so reading it first never pairs it with older data.
    [{:generation, generation}] = :ets.lookup(table, :generation)
    [{:index, index}] = :ets.lookup(table, :index)

    daemon =
      case :ets.lookup(table, :daemon) do
        [{:daemon, block}] -> block
        [] -> nil
      end

    {:ok, generation, index, daemon}
  rescue
    # The server's table dies with it between the call and the read.
    ArgumentError -> {:error, :index_not_running}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    case Keyword.get(opts, :subscribe, &Core.subscribe_sources/0).() do
      :ok ->
        table = :ets.new(__MODULE__, [:protected, read_concurrency: true])
        :ets.insert(table, {:generation, 0})

        {:ok,
         %{parts: %{}, index: {:error, :loading}, generation: 0, dirty: MapSet.new(), timer: nil, task: nil, daemon: nil, daemon_task: nil, waiting: [], table: table, opts: opts, history_at: nil},
         {:continue, :load}}

      {:error, reason} ->
        {:stop, {:subscription_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:load, state) do
    send(self(), :daemon_tick)
    {:noreply, read(state, :all)}
  end

  @impl true
  def handle_call(:table, from, %{index: {:error, :loading}} = state), do: {:noreply, %{state | waiting: [from | state.waiting]}}
  def handle_call(:table, _from, state), do: {:reply, {:ok, state.table, clock(state)}, state}
  # Answers while the index still loads, so a mount can show the last daemon reading at once (#4915).
  def handle_call(:daemon, _from, state), do: {:reply, state.daemon, state}

  def handle_call({:earlier, before, zone, days}, _from, state) do
    reply = with {:ok, index} <- state.index, do: Core.earlier(index, before, zone, days)
    {:reply, reply, state}
  end

  def handle_call({:ticket, id}, _from, state) do
    reply =
      with {:ok, index} <- state.index do
        case Map.fetch(index.all, to_string(id)) do
          {:ok, row} -> {:ok, row}
          :error -> {:error, :not_found}
        end
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({tag, _payload}, state) when is_map_key(@signals, tag), do: {:noreply, dirty(state, @signals[tag])}
  def handle_info(:flush, %{task: nil} = state), do: {:noreply, read(%{state | timer: nil}, state.dirty)}
  def handle_info(:flush, state), do: {:noreply, %{state | timer: nil}}

  def handle_info({ref, parts}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(state.task.deadline)
    {:noreply, finish(%{state | task: nil}, parts, state.task.dirty)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref, dirty: dirty}} = state) do
    Process.cancel_timer(state.task.deadline)
    keys = if dirty == :all, do: Map.keys(state.parts) ++ ~w(settings history now planned not_queued)a, else: MapSet.to_list(dirty)
    failure = if state.task[:timed_out?], do: :timeout, else: :read_failed
    Logger.warning("build_index read_task_failed=#{inspect(reason, limit: 20, printable_limit: 200)} failure=#{failure} parts=#{Enum.join(Enum.uniq(keys), ",")}")
    parts = Enum.reduce(keys, state.parts, &Map.put(&2, &1, {:error, failure}))
    {:noreply, finish(%{state | task: nil}, parts, dirty)}
  end

  def handle_info({:read_timeout, ref}, %{task: %{ref: ref, pid: pid}} = state) do
    part = Process.info(pid, :dictionary) |> read_part_from_dictionary()
    stack = inspect(Process.info(pid, :current_stacktrace), limit: :infinity, printable_limit: 4_000)
    Logger.warning("build_index read_timeout after_ms=#{Keyword.get(state.opts, :read_timeout, 3_500)} part=#{part} stack=#{stack}")
    Process.exit(pid, :kill)
    {:noreply, put_in(state.task[:timed_out?], true)}
  end

  def handle_info(:daemon_tick, %{daemon_task: nil} = state) do
    reader = Keyword.get(state.opts, :daemon_read, &Freshness.read_daemon/1)
    opts = state.opts
    task = Task.async(fn -> reader.(opts) end)
    {:noreply, %{state | daemon_task: task}}
  end

  def handle_info(:daemon_tick, state), do: {:noreply, state}

  def handle_info({ref, block}, %{daemon_task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, daemon_result(state, block)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{daemon_task: %{ref: ref}} = state),
    do: {:noreply, daemon_result(state, %{state: "unknown", heartbeat_at: nil, observed_at: clock(state)})}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for task <- [state.task, state.daemon_task], task != nil, do: Process.exit(task.pid, :kill)
    :ok
  end

  defp daemon_result(state, block) do
    block = carry_heartbeat(block, state.daemon)
    changed? = Freshness.push_daemon?(state.daemon, block)
    generation = if changed?, do: state.generation + 1, else: state.generation
    if changed?, do: broadcast(state, %{index_generation: generation, now: clock(state), upsert: [], remove: [], set: %{daemon: block}, resync: false})
    timer = Keyword.get(state.opts, :daemon_timer, &Process.send_after/3)
    timer.(self(), :daemon_tick, 10_000)
    :ets.insert(state.table, {:daemon, block})
    :ets.insert(state.table, {:generation, generation})
    %{state | daemon_task: nil, daemon: block, generation: generation}
  end

  # An unread snapshot keeps the last good heartbeat so the footer can state its age (#4770).
  defp carry_heartbeat(%{state: "unknown", heartbeat_at: nil} = block, %{heartbeat_at: at}), do: %{block | heartbeat_at: at}
  defp carry_heartbeat(block, _previous), do: block

  defp dirty(state, keys) do
    state = %{state | dirty: Enum.reduce(keys ++ [:settings, :repository], state.dirty, &MapSet.put(&2, &1))}
    if state.task == nil, do: schedule(state), else: state
  end

  defp schedule(%{timer: nil} = state) do
    timer = Keyword.get(state.opts, :timer, &Process.send_after/3)
    %{state | timer: timer.(self(), :flush, @window)}
  end

  defp schedule(state), do: state

  defp read(state, keys) do
    reader = Keyword.get(state.opts, :read, &IndexReader.read/3)
    parts = state.parts
    opts = state.opts
    task = Task.async(fn -> reader.(keys, parts, opts) end)
    # trap_exit handles a failed read; the link terminates workers when the owner dies.
    deadline = Process.send_after(self(), {:read_timeout, task.ref}, Keyword.get(opts, :read_timeout, 3_500))
    %{state | dirty: MapSet.new(), task: %{ref: task.ref, pid: task.pid, dirty: keys, deadline: deadline}}
  end

  defp finish(state, parts, keys) do
    {parts, history_at} = HistoryCarry.carry(state.parts, parts, keys, state.history_at, clock(state))
    next = Core.assemble(parts, now: clock(state))
    changes = changes(state.index, next)
    generation = if changes, do: state.generation + 1, else: state.generation
    if changes, do: broadcast(state, Map.merge(changes, %{index_generation: generation, now: clock(state)}))
    state = %{state | parts: parts, index: next, generation: generation, history_at: history_at}
    :ets.insert(state.table, {:index, with({:ok, index} <- next, do: {:ok, Core.base(index)})})
    :ets.insert(state.table, {:generation, generation})
    Enum.each(state.waiting, &GenServer.reply(&1, {:ok, state.table, clock(state)}))

    state = %{state | waiting: []}
    if MapSet.size(state.dirty) > 0, do: schedule(state), else: state
  end

  defp changes({:ok, old}, {:ok, new}) do
    # An empty unavailable/backfilling window has no cutoff: pull a bounded day window on recovery.
    if old.hist == [] and new.hist != [] and old.sources.history.state in ["unavailable", "incomplete"] do
      %{resync: true}
    else
      ordinary_changes(old, new)
    end
  end

  defp changes(_, _), do: %{resync: true}

  defp ordinary_changes(old, new) do
    case Core.diff(old, new) do
      %{upsert: [], remove: [], set: set} when map_size(set) == 0 -> nil
      diff -> Map.put(diff, :resync, false)
    end
  end

  defp broadcast(state, changes), do: Keyword.get(state.opts, :broadcast, &Core.broadcast/1).(changes)
  defp clock(state), do: Keyword.get(state.opts, :clock, fn -> System.system_time(:millisecond) end).()
  defp read_part_from_dictionary({:dictionary, dictionary}), do: Keyword.get(dictionary, :aiur_build_index_read_part, :unknown)
  defp read_part_from_dictionary(_info), do: :unknown
end

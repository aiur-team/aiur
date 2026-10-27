defmodule AiurWeb.Build.Index do
  @moduledoc "One async, coalescing build-home index per dashboard daemon."
  use GenServer
  alias Aiur.BuildOrder.Index, as: Core
  alias AiurWeb.Build.{Freshness, HistoryCarry, IndexReader}
  alias AiurWeb.Build.Index.RefreshState
  require Logger
  @window 250
  @max_backoff 60_000
  @signals %{
    build_order_history_changed: ~w(history health catch_up planned not_queued packs)a,
    build_order_features_changed: [:features, :packs],
    build_order_planning_pack_changed: [:pack_metadata],
    build_estimates_changed: [:estimates],
    poll_state_changed: [:capacity],
    epic_overrides_changed: [:overrides],
    build_progress_changed: ~w(queue planned not_queued packs)a,
    build_queue_changed: ~w(queue planned not_queued packs)a,
    open_tickets_updated: ~w(open planned not_queued packs)a,
    build_order_pack_status_changed: [:packs],
    ticket_activity_changed: ~w(now planned not_queued)a,
    running_changed: ~w(now planned not_queued)a
  }
  @read_parts ~w(history health catch_up features overrides settings repository open queue now planned not_queued estimates capacity packs pack_metadata)a

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Cuts one mount's window in the caller, so concurrent mounts never queue behind the server's sort and page work."
  @spec window(GenServer.server(), String.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def window(server, zone, timeout \\ 5_000) do
    case GenServer.call(server, :table, timeout) do
      {:ok, table, now} ->
        with {:ok, generation, index, daemon} <- read_table(table),
             {:ok, base} <- index,
             do:
               {:ok,
                base
                |> Core.window(zone, now)
                |> Map.merge(%{index_generation: generation, daemon: daemon})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec subscribe(GenServer.server()) :: :ok | {:error, term()}
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

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

    idle_without_subscribers? = Keyword.get(opts, :idle_without_subscribers?, false)
    table = :ets.new(__MODULE__, [:protected, read_concurrency: true])
    :ets.insert(table, {:generation, 0})

    state = %{
      parts: %{},
      index: {:error, :loading},
      generation: 0,
      dirty: MapSet.new(),
      timer: nil,
      task: nil,
      daemon: nil,
      daemon_task: nil,
      daemon_timer_ref: nil,
      waiting: [],
      failures: 0,
      settings_loading_since_ms: nil,
      table: table,
      opts: opts,
      history_at: nil,
      subscribers: %{},
      idle_without_subscribers?: idle_without_subscribers?,
      active?: not idle_without_subscribers?
    }

    if idle_without_subscribers? do
      {:ok, state}
    else
      case Keyword.get(opts, :subscribe, &Core.subscribe_sources/0).() do
        :ok -> {:ok, state, {:continue, :load}}
        {:error, reason} -> {:stop, {:subscription_failed, reason}}
      end
    end
  end

  @impl true
  def handle_continue(:load, state) do
    {:noreply, activate(state)}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) when is_pid(pid) do
    case Map.fetch(state.subscribers, pid) do
      {:ok, _monitor_ref} ->
        {:reply, :ok, state}

      :error ->
        state = %{state | subscribers: Map.put(state.subscribers, pid, Process.monitor(pid))}

        case activate_if_needed(state) do
          {:ok, state} ->
            {:reply, :ok, state}

          {:error, reason, state} ->
            {:reply, {:error, reason}, %{state | subscribers: Map.delete(state.subscribers, pid)}}
        end
    end
  end

  def handle_call(:table, from, state) do
    case activate_if_needed(state) do
      {:ok, %{index: {:error, :loading}} = state} ->
        {:noreply, %{state | waiting: [from | state.waiting]}}

      {:ok, state} ->
        {:reply, {:ok, state.table, clock(state)}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

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

  def handle_call({:unit_row, id}, _from, state) do
    rows =
      case state.parts[:now] do
        %{source: %{state: "ok"}, unit_rows: rows} when is_map(rows) -> rows
        _ -> %{}
      end

    reply =
      case Map.fetch(rows, id) do
        {:ok, row} -> {:ok, row}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(
        {tag, _payload},
        %{active?: false, idle_without_subscribers?: true, subscribers: subscribers} = state
      )
      when map_size(subscribers) == 0 and is_map_key(@signals, tag),
      do: {:noreply, state}

  def handle_info({tag, _payload}, state) when is_map_key(@signals, tag),
    do: {:noreply, dirty(state, @signals[tag])}

  def handle_info(
        :fleet_changed,
        %{active?: false, idle_without_subscribers?: true, subscribers: subscribers} = state
      )
      when map_size(subscribers) == 0,
      do: {:noreply, state}

  def handle_info(:fleet_changed, state), do: {:noreply, dirty(state, [:capacity])}
  def handle_info(:flush, %{active?: false} = state), do: {:noreply, %{state | timer: nil}}

  def handle_info(:flush, %{task: nil} = state),
    do: {:noreply, read(%{state | timer: nil}, state.dirty)}

  def handle_info(:flush, state), do: {:noreply, %{state | timer: nil}}

  def handle_info({ref, parts}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(state.task.deadline)
    dirty = dirty_set(state.task.dirty)
    parts = RefreshState.clear_read_staleness(parts, dirty)

    settings_loading? =
      match?({:error, :settings_loading}, Core.assemble(parts, now: clock(state)))

    failures =
      if match?({:error, _}, parts[:now]) or settings_loading?, do: state.failures, else: 0

    {:noreply, finish(%{state | task: nil, failures: failures}, parts, dirty)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    Process.cancel_timer(state.task.deadline)
    failure = if state.task[:timed_out?], do: :timeout, else: :read_failed
    part = state.task[:timed_out_part]
    dirty = dirty_set(state.task.dirty)

    # The hung part is not reread; it stays stale until its own signal, even with no mark_failed_part clause.
    retry = if part in [nil, :unknown], do: dirty, else: MapSet.delete(dirty, part)
    cause = if part in [nil, :unknown], do: :unknown, else: failure

    # An unlocated failure rereads every part, so back off rather than loop on a reader that always crashes.
    failures = if cause == :unknown, do: state.failures + 1, else: state.failures

    Logger.warning(
      "build_index read_task_failed=#{inspect(reason, limit: 20, printable_limit: 200)} failure=#{failure} parts=#{part || :unknown} part=#{part || :unknown} retry=#{Enum.join(MapSet.to_list(retry), ",")}"
    )

    parts = RefreshState.record_read_staleness(state.parts, dirty, cause)

    parts =
      parts
      |> RefreshState.mark_failed_part(part, failure)
      |> RefreshState.retain_failed_agents(state.parts, part, failure)

    dirty = MapSet.union(state.dirty, retry)

    {:noreply,
     finish(
       %{state | task: nil, dirty: dirty, failures: failures},
       parts,
       dirty_set(state.task.dirty)
     )}
  end

  def handle_info({:read_timeout, ref}, %{task: %{ref: ref, pid: pid}} = state) do
    part = Process.info(pid, :dictionary) |> read_part_from_dictionary()

    stack =
      inspect(Process.info(pid, :current_stacktrace), limit: :infinity, printable_limit: 4_000)

    Logger.warning("build_index read_timeout after_ms=#{Keyword.get(state.opts, :read_timeout, 3_500)} part=#{part} stack=#{stack}")

    Process.exit(pid, :kill)
    {:noreply, %{state | task: Map.merge(state.task, %{timed_out?: true, timed_out_part: part})}}
  end

  def handle_info(:daemon_tick, %{active?: false} = state), do: {:noreply, state}

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

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.fetch(state.subscribers, pid) do
      {:ok, ^ref} ->
        subscribers = Map.delete(state.subscribers, pid)
        state = %{state | subscribers: subscribers}

        if state.idle_without_subscribers? and map_size(subscribers) == 0,
          do: {:noreply, deactivate(state)},
          else: {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

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

    if changed?,
      do:
        broadcast(state, %{
          index_generation: generation,
          now: clock(state),
          upsert: [],
          remove: [],
          set: %{daemon: block},
          resync: false
        })

    timer_ref =
      if state.active? do
        timer = Keyword.get(state.opts, :daemon_timer, &Process.send_after/3)
        timer.(self(), :daemon_tick, 10_000)
      end

    :ets.insert(state.table, {:daemon, block})
    :ets.insert(state.table, {:generation, generation})

    %{
      state
      | daemon_task: nil,
        daemon_timer_ref: timer_ref,
        daemon: block,
        generation: generation
    }
  end

  # An unread snapshot keeps the last good heartbeat so the footer can state its age (#4770).
  defp carry_heartbeat(%{state: "unknown", heartbeat_at: nil} = block, %{heartbeat_at: at}),
    do: %{block | heartbeat_at: at}

  defp carry_heartbeat(block, _previous), do: block

  defp dirty(state, keys) do
    state = %{
      state
      | dirty: Enum.reduce(keys ++ [:settings, :repository], state.dirty, &MapSet.put(&2, &1))
    }

    if state.task == nil, do: schedule(state), else: state
  end

  defp schedule(%{timer: nil} = state) do
    timer = Keyword.get(state.opts, :timer, &Process.send_after/3)

    %{
      state
      | timer:
          timer.(
            self(),
            :flush,
            min(@window * Integer.pow(2, min(state.failures, 8)), @max_backoff)
          )
    }
  end

  defp schedule(state), do: state

  defp activate_if_needed(%{active?: true} = state), do: {:ok, state}

  defp activate_if_needed(state) do
    case Keyword.get(state.opts, :subscribe, &Core.subscribe_sources/0).() do
      :ok -> {:ok, activate(%{state | active?: true})}
      {:error, reason} -> {:error, {:subscription_failed, reason}, state}
    end
  end

  defp activate(state) do
    send(self(), :daemon_tick)
    read(state, :all)
  end

  defp deactivate(state) do
    cancel_timer(state.timer)
    cancel_timer(state.daemon_timer_ref)
    stop_task(state.task)
    stop_task(state.daemon_task)

    %{
      state
      | active?: false,
        timer: nil,
        daemon_timer_ref: nil,
        task: nil,
        daemon_task: nil,
        dirty: MapSet.new()
    }
  end

  defp stop_task(nil), do: :ok

  defp stop_task(%{ref: ref, pid: pid} = task) do
    if deadline = Map.get(task, :deadline), do: cancel_timer(deadline)
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    :ok
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    _ = Process.cancel_timer(timer_ref)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp read(state, keys) do
    reader = Keyword.get(state.opts, :read, &IndexReader.read/3)
    parts = state.parts
    opts = state.opts
    task = Task.async(fn -> reader.(keys, parts, opts) end)
    # trap_exit handles a failed read; the link terminates workers when the owner dies.
    deadline =
      Process.send_after(
        self(),
        {:read_timeout, task.ref},
        Keyword.get(opts, :read_timeout, 3_500)
      )

    %{
      state
      | dirty: MapSet.new(),
        task: %{ref: task.ref, pid: task.pid, dirty: keys, deadline: deadline}
    }
  end

  defp finish(state, parts, keys) do
    {parts, history_at} =
      HistoryCarry.carry(state.parts, parts, keys, state.history_at, clock(state))

    next = Core.assemble(parts, now: clock(state))

    {parts, next, settings_loading_since_ms} =
      RefreshState.expire_settings_loading(state, parts, next, clock(state))

    changes = RefreshState.changes(state.index, next)
    generation = if changes, do: state.generation + 1, else: state.generation

    if changes,
      do: broadcast(state, Map.merge(changes, %{index_generation: generation, now: clock(state)}))

    now_failed? = match?({:error, _}, parts[:now])
    {failures, retry_dirty} = RefreshState.retry_after_finish(state, next, now_failed?, parts)

    state = %{
      state
      | parts: parts,
        index: next,
        generation: generation,
        history_at: history_at,
        failures: failures,
        dirty: retry_dirty,
        settings_loading_since_ms: settings_loading_since_ms
    }

    :ets.insert(state.table, {:index, with({:ok, index} <- next, do: {:ok, Core.base(index)})})
    :ets.insert(state.table, {:generation, generation})
    Enum.each(state.waiting, &GenServer.reply(&1, {:ok, state.table, clock(state)}))

    state = %{state | waiting: []}

    cond do
      MapSet.size(state.dirty) > 0 -> schedule(state)
      now_failed? -> schedule(state)
      true -> state
    end
  end

  defp broadcast(state, changes),
    do: Keyword.get(state.opts, :broadcast, &Core.broadcast/1).(changes)

  defp clock(state),
    do: Keyword.get(state.opts, :clock, fn -> System.system_time(:millisecond) end).()

  defp read_part_from_dictionary({:dictionary, dictionary}),
    do: Keyword.get(dictionary, :aiur_build_index_read_part, :unknown)

  defp read_part_from_dictionary(_info), do: :unknown

  defp dirty_set(:all), do: MapSet.new(@read_parts)
  defp dirty_set(%MapSet{} = dirty), do: dirty
end

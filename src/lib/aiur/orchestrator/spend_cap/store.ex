defmodule Aiur.Orchestrator.SpendCap.Store do
  @moduledoc false
  use GenServer
  require Logger

  alias Aiur.{AgentPubSub, Events, Signal}
  alias Aiur.Orchestrator.SpendCap.{Evaluation, OutboundEvents, Persistence, Record, Runtime, Stop}
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.TrackerIdentity
  alias Aiur.UsageAggregate

  @dispatch_table Aiur.Orchestrator.SpendCap.DispatchTable
  @refresh_debounce_ms 100
  @retry_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec put(GenServer.server(), TrackerIdentity.t(), term()) :: {:ok, map()} | {:error, atom()}
  def put(server \\ __MODULE__, identity, amount), do: GenServer.call(server, {:put, identity, amount})

  @spec get(GenServer.server(), String.t()) :: {:ok, map()} | {:error, atom()}
  def get(server \\ __MODULE__, identifier), do: GenServer.call(server, {:get, identifier})

  @spec delete(GenServer.server(), String.t()) :: :ok | {:error, atom()}
  def delete(server \\ __MODULE__, identifier), do: GenServer.call(server, {:delete, identifier})

  @spec health(GenServer.server()) :: :healthy | {:unavailable, atom()}
  def health(server \\ __MODULE__), do: GenServer.call(server, :health)

  @spec admission(GenServer.server(), TrackerIdentity.t()) :: :allow | {:skip, :spend_cap_exhausted | :spend_cap_unavailable}
  def admission(server, %TrackerIdentity{} = identity), do: GenServer.call(server, {:admission, identity})

  @spec dispatch_admission(TrackerIdentity.t()) :: :allow | {:skip, :spend_cap_exhausted | :spend_cap_unavailable}
  def dispatch_admission(%TrackerIdentity{} = identity) do
    case safe_lookup(@dispatch_table, :health) do
      [{:health, :healthy}] -> dispatch_record_admission(identity)
      _other -> {:skip, :spend_cap_unavailable}
    end
  end

  def dispatch_admission(_identity), do: {:skip, :spend_cap_unavailable}

  defp dispatch_record_admission(identity) do
    case safe_lookup(@dispatch_table, Record.key(identity)) do
      [{_key, :budget_exhausted}] -> {:skip, :spend_cap_exhausted}
      [{_key, :unavailable}] -> {:skip, :spend_cap_unavailable}
      _other -> :allow
    end
  end

  @impl true
  def init(opts) do
    repository = Keyword.get_lazy(opts, :repository, &Aiur.Tracker.project_identity/0)
    table = create_table(Keyword.get(opts, :table, @dispatch_table))

    base = %{
      repository: repository,
      records: %{},
      health: {:unavailable, :spend_cap_state_unavailable},
      path: nil,
      writer: Keyword.get(opts, :writer, &Aiur.Fs.atomic_write/3),
      table: table,
      inflight: MapSet.new(),
      retrying: MapSet.new(),
      effect_retry_counts: %{},
      running_keys: MapSet.new(),
      running_identifiers: MapSet.new(),
      refresh_scheduled?: false,
      partial_alerted: MapSet.new(),
      usage_fun: Keyword.get(opts, :usage_fun, &Runtime.usage/1),
      snapshot_fun: Keyword.get(opts, :snapshot_fun, &UsageAggregate.cells_snapshot/0),
      project_fun: Keyword.get(opts, :project_fun, &Runtime.usage_from_snapshot/2),
      now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0),
      subscribe_fun: Keyword.get(opts, :subscribe_fun, &UsageAggregate.subscribe/0),
      running_subscribe_fun: Keyword.get(opts, :running_subscribe_fun, &AgentPubSub.subscribe_running/0),
      alert_fun: Keyword.get(opts, :alert_fun, &Signal.alert/2),
      reserve_event_id_fun: Keyword.get(opts, :reserve_event_id_fun, &Events.reserve_durable_id/0),
      stop_fun: Keyword.get(opts, :stop_fun, fn identity, _end_state -> Stop.request(identity) end),
      event_fun: Keyword.get(opts, :event_fun, &OutboundEvents.publish/4),
      transition_fun: Keyword.get(opts, :transition_fun, &transition_ticket/2),
      task_start_fun: Keyword.get(opts, :task_start_fun, &start_effect_task/1),
      refresh_debounce_ms: Keyword.get(opts, :refresh_debounce_ms, @refresh_debounce_ms),
      retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
      retry_max_ms: Keyword.get(opts, :retry_max_ms, 60_000),
      sync_fun: Keyword.get(opts, :filesystem_sync_fun, &Aiur.Fs.sync_filesystem/0)
    }

    state =
      if is_binary(repository) and repository != "" do
        case Persistence.load(opts, repository) do
          {:ok, path, records, writer} -> %{base | path: path, records: records, writer: writer, health: :healthy}
          {:error, reason, path, writer} -> %{base | path: path, writer: writer, health: {:unavailable, reason}}
        end
      else
        %{base | health: {:unavailable, :spend_cap_state_unavailable}}
      end

    sync_table(state)
    {:ok, state, {:continue, :subscribe_and_resume}}
  end

  @impl true
  def handle_continue(:subscribe_and_resume, state) do
    with :ok <- safe_call(state.subscribe_fun),
         :ok <- safe_call(state.running_subscribe_fun) do
      send(self(), :resume_spend_cap_effects)
      {:noreply, state}
    else
      reason ->
        Logger.error("spend-cap subscription failed reason=#{inspect(reason)}")
        state = %{state | health: {:unavailable, :spend_cap_subscription_failed}}
        sync_table(state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:health, _from, state), do: {:reply, state.health, state}

  def handle_call({:admission, identity}, _from, state) do
    {:reply, admission_for(state, identity), state}
  end

  def handle_call({:put, %TrackerIdentity{} = identity, amount}, _from, %{health: :healthy} = state) do
    key = Record.key(identity)

    cond do
      is_nil(key) ->
        {:reply, {:error, :invalid_identity}, state}

      match?(%Record{state: :budget_exhausted}, Map.get(state.records, key)) ->
        {:reply, {:error, :spend_cap_exhausted}, state}

      true ->
        configured_at = state.now_fun.()

        with {:ok, record} <- Record.new(identity, amount, configured_at),
             {_status, record} <- Evaluation.refresh(record, safe_usage(state, identity), configured_at),
             {:ok, state} <- persist_records(state, Map.put(state.records, key, record)) do
          state = state |> Runtime.update_partial_attention(key, record, self()) |> drive_effects()
          {:reply, {:ok, Record.public(record)}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:put, _identity, _amount}, _from, state), do: {:reply, {:error, :spend_cap_unavailable}, state}

  def handle_call({:get, identifier}, _from, %{health: :healthy} = state) when is_binary(identifier) do
    case find_by_identifier(state.records, identifier) do
      {:ok, key, record} ->
        {record, state} = refresh_one(state, key, record)
        {:reply, {:ok, Record.public(record)}, drive_effects(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get, _identifier}, _from, state), do: {:reply, {:error, :spend_cap_unavailable}, state}

  def handle_call({:delete, identifier}, _from, %{health: :healthy} = state) when is_binary(identifier) do
    case find_by_identifier(state.records, identifier) do
      {:ok, _key, %Record{state: :budget_exhausted, effects: %{tracker_transition: transition}}} when transition != :completed ->
        {:reply, {:error, :exhaustion_transition_pending}, state}

      {:ok, key, _record} ->
        case persist_records(state, Map.delete(state.records, key)) do
          {:ok, state} -> {:reply, :ok, clear_retry(state, key)}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete, _identifier}, _from, state), do: {:reply, {:error, :spend_cap_unavailable}, state}

  @impl true
  def handle_info({:usage_aggregate_changed, _payload}, %{health: :healthy} = state) do
    {:noreply, schedule_refresh(state)}
  end

  def handle_info({:usage_aggregate_changed, _payload}, state), do: {:noreply, state}

  def handle_info({:running_changed, summaries}, state) when is_list(summaries) do
    {running_keys, running_identifiers} = Runtime.running_records(summaries)

    state =
      state
      |> Map.merge(%{running_keys: running_keys, running_identifiers: running_identifiers})
      |> schedule_refresh()

    {:noreply, state}
  end

  def handle_info(:refresh_running_spend_caps, %{health: :healthy} = state) do
    state = %{state | refresh_scheduled?: false}
    {:noreply, state |> refresh_running() |> drive_effects()}
  end

  def handle_info(:refresh_running_spend_caps, state), do: {:noreply, %{state | refresh_scheduled?: false}}

  def handle_info(:resume_spend_cap_effects, state), do: {:noreply, drive_effects(state)}

  def handle_info({:spend_cap_partial_alert, key, disposition, result}, state) do
    {:noreply, Runtime.finish_partial_attention(state, key, disposition, result)}
  end

  def handle_info({:spend_cap_effect, key, effect, result}, state) do
    state = %{state | inflight: MapSet.delete(state.inflight, key)}

    record = Map.get(state.records, key)

    case {record, effect_success?(record, effect, result)} do
      {%Record{} = record, true} ->
        record = Record.effect(record, effect, :completed)
        state = clear_retry(state, key)

        case persist_records(state, Map.put(state.records, key, record)) do
          {:ok, state} -> {:noreply, drive_effects(state)}
          {:error, _reason} -> {:noreply, state}
        end

      {%Record{} = record, false} ->
        Logger.warning("spend-cap effect failed ticket=#{record.identity.identifier} effect=#{effect} reason=#{inspect(result)}")
        {:noreply, schedule_retry(state, key)}

      {nil, _success} ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_spend_cap_effects, key, attempt}, state) do
    if Map.get(state.effect_retry_counts, key) == attempt do
      {:noreply, state |> Map.update!(:retrying, &MapSet.delete(&1, key)) |> drive_effects()}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_refresh(%{health: :healthy, refresh_scheduled?: false} = state) do
    if Enum.any?(state.records, fn {key, record} -> refreshable?(state, key, record) end) do
      Process.send_after(self(), :refresh_running_spend_caps, state.refresh_debounce_ms)
      %{state | refresh_scheduled?: true}
    else
      state
    end
  end

  defp schedule_refresh(state), do: state

  defp refresh_running(state) do
    snapshot = Runtime.snapshot(state.snapshot_fun)

    Enum.reduce(state.records, state, fn {key, record}, current ->
      if refreshable?(current, key, record) do
        usage = Runtime.project(current.project_fun, snapshot, record.identity)
        {_record, current} = refresh_one(current, key, record, usage)
        current
      else
        current
      end
    end)
  end

  defp refreshable?(_state, _key, %Record{state: :budget_exhausted}), do: false
  defp refreshable?(_state, _key, %Record{state: :unavailable}), do: true

  defp refreshable?(state, key, %Record{} = record) do
    MapSet.member?(state.running_keys, key) or MapSet.member?(state.running_identifiers, record.identity.identifier)
  end

  defp refresh_one(state, _key, %Record{state: :budget_exhausted} = record), do: {record, state}

  defp refresh_one(state, key, record) do
    refresh_one(state, key, record, safe_usage(state, record.identity))
  end

  defp refresh_one(state, key, record, usage) do
    {_status, refreshed} = Evaluation.refresh(record, usage, state.now_fun.())

    {record, state} =
      cond do
        refreshed == record ->
          {record, state}

        refreshed.state == :budget_exhausted ->
          case persist_records(state, Map.put(state.records, key, refreshed)) do
            {:ok, state} -> {refreshed, state}
            {:error, _reason} -> {record, state}
          end

        true ->
          state = %{state | records: Map.put(state.records, key, refreshed)}
          sync_record(state.table, key, refreshed)
          {refreshed, state}
      end

    {record, Runtime.update_partial_attention(state, key, record, self())}
  end

  defp persist_records(state, records) do
    case Persistence.write(state.path, state.repository, records, state.writer, state.sync_fun) do
      :ok ->
        state = %{state | records: records}
        sync_table(state)
        {:ok, state}

      {:error, reason} ->
        state = %{state | health: {:unavailable, reason}}
        sync_table(state)
        {:error, reason}
    end
  end

  defp drive_effects(%{health: :healthy} = state) do
    Enum.reduce(state.records, state, fn {key, record}, current -> maybe_start_effect(current, key, record) end)
  end

  defp drive_effects(state), do: state

  defp maybe_start_effect(state, key, %Record{} = record) do
    if MapSet.member?(state.inflight, key) or MapSet.member?(state.retrying, key) do
      state
    else
      case Record.next_effect(record) do
        nil -> state
        :event -> prepare_and_start_event(state, key, record)
        effect -> start_effect(state, key, record, effect)
      end
    end
  end

  defp prepare_and_start_event(state, key, %Record{event_id: nil} = record) do
    case safe_call(state.reserve_event_id_fun) do
      {:ok, event_id} when is_integer(event_id) and event_id > 0 ->
        record = %{record | event_id: event_id}

        case persist_records(state, Map.put(state.records, key, record)) do
          {:ok, state} -> start_effect(state, key, record, :event)
          {:error, _reason} -> state
        end

      other ->
        Logger.warning("spend-cap event id reservation failed ticket=#{record.identity.identifier} reason=#{inspect(other)}")
        schedule_retry(state, key)
    end
  end

  defp prepare_and_start_event(state, key, record), do: start_effect(state, key, record, :event)

  defp start_effect(state, key, record, effect) do
    owner = self()
    run = fn -> send(owner, {:spend_cap_effect, key, effect, run_effect(state, record, effect)}) end

    case state.task_start_fun.(run) do
      {:ok, _pid} ->
        %{state | inflight: MapSet.put(state.inflight, key)}

      :ok ->
        %{state | inflight: MapSet.put(state.inflight, key)}

      error ->
        Logger.warning("spend-cap task start failed ticket=#{record.identity.identifier} effect=#{effect} reason=#{inspect(error)}")
        schedule_retry(state, key)
    end
  end

  defp run_effect(state, record, :stop), do: safe_call(fn -> state.stop_fun.(record.identity, :budget_exhausted) end)

  defp run_effect(state, record, :event) do
    topic = "ticket.#{record.identity.identifier}.usage.spend_cap_reached"
    payload = Record.event_payload(record)
    safe_call(fn -> OutboundEvents.publish(state.event_fun, topic, payload, record.event_id, record.identity) end)
  end

  defp run_effect(state, record, :tracker_transition) do
    safe_call(fn -> state.transition_fun.(record.identity.identifier, "budget-exhausted") end)
  end

  defp effect_success?(%Record{}, :stop, :ok), do: true
  defp effect_success?(%Record{event_id: event_id}, :event, {:ok, event_id, _subscribers}) when is_integer(event_id), do: true
  defp effect_success?(%Record{}, :tracker_transition, :ok), do: true
  defp effect_success?(_record, _effect, _result), do: false

  defp schedule_retry(state, key) do
    if MapSet.member?(state.retrying, key) do
      state
    else
      attempt = Map.get(state.effect_retry_counts, key, 0) + 1
      delay = min(state.retry_ms * attempt, state.retry_max_ms)
      Process.send_after(self(), {:retry_spend_cap_effects, key, attempt}, delay)

      %{
        state
        | retrying: MapSet.put(state.retrying, key),
          effect_retry_counts: Map.put(state.effect_retry_counts, key, attempt)
      }
    end
  end

  defp clear_retry(state, key) do
    %{
      state
      | retrying: MapSet.delete(state.retrying, key),
        effect_retry_counts: Map.delete(state.effect_retry_counts, key)
    }
  end

  defp admission_for(%{health: :healthy} = state, %TrackerIdentity{} = identity) do
    case Map.get(state.records, Record.key(identity)) do
      %Record{state: :budget_exhausted} -> {:skip, :spend_cap_exhausted}
      %Record{state: :unavailable} -> {:skip, :spend_cap_unavailable}
      _record -> :allow
    end
  end

  defp admission_for(_state, _identity), do: {:skip, :spend_cap_unavailable}

  defp find_by_identifier(records, identifier) do
    case Enum.filter(records, fn {_key, record} -> record.identity.identifier == identifier end) do
      [{key, record}] -> {:ok, key, record}
      [] -> {:error, :spend_cap_not_found}
      _many -> {:error, :ambiguous_identifier}
    end
  end

  defp safe_usage(state, identity) do
    case safe_call(fn -> state.usage_fun.(identity) end) do
      usage when is_map(usage) -> usage
      _other -> %{state: :unavailable}
    end
  end

  defp transition_ticket(identifier, state) do
    TicketTransition.write_state(identifier, state, writer: :spend_cap)
  end

  defp start_effect_task(fun), do: Task.Supervisor.start_child(Aiur.TaskSupervisor, fun)

  defp create_table(nil), do: :ets.new(__MODULE__, [:protected, :set, read_concurrency: true])

  defp create_table(name) when is_atom(name) do
    :ets.new(name, [:named_table, :protected, :set, read_concurrency: true])
  end

  defp sync_table(state) do
    :ets.delete_all_objects(state.table)
    :ets.insert(state.table, {:health, state.health})
    Enum.each(state.records, fn {key, record} -> :ets.insert(state.table, {key, record.state}) end)
    :ok
  end

  defp sync_record(table, key, record), do: :ets.insert(table, {key, record.state})

  defp safe_lookup(table, key) do
    :ets.lookup(table, key)
  rescue
    ArgumentError -> []
  end

  defp safe_call(fun) do
    fun.()
  rescue
    error -> {:error, {:exception, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end

defmodule Aiur.Events.Outbound.ExportJournal do
  # aiur:event-bus-boundary-member
  @moduledoc """
  Durable, bounded admission queue for versioned outbound events.

  Records are fsynced before live consumers are notified. Delivered records
  are compacted only after the durable consumer cursor says they were
  acknowledged; pending records are never evicted to make room.
  """

  use GenServer

  @behaviour Aiur.Events.DurableConsumer.Source

  alias Aiur.Config.Paths
  alias Aiur.Events.{Exchange, Journal}
  alias Aiur.Events.Outbound.Event
  alias Aiur.JsonStore

  require Logger

  @bindings [
    "ticket.*.lifecycle.changed",
    "ticket.*.usage.changed",
    "ticket.*.usage.spend_cap_reached",
    "ticket.*.cancel.result",
    "ticket.*.agent.progress",
    "ticket.*.agent.progress.checkin",
    "ticket.*.agent.progress.phase"
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Admits from the shared publisher when outbound export is running."
  @spec maybe_ingest(map(), timeout()) :: {:ok, pos_integer()} | {:error, term()} | :drop | :not_running
  def maybe_ingest(event, timeout \\ 100) when is_map(event) do
    case Process.whereis(__MODULE__) do
      nil -> :not_running
      server -> ingest(server, event, timeout)
    end
  catch
    :exit, reason -> {:error, {:journal_unavailable, reason}}
  end

  @doc "Synchronously admits an internal event; primarily useful at explicit producer boundaries."
  @spec ingest(map()) :: {:ok, pos_integer()} | {:error, term()} | :drop
  def ingest(event), do: ingest(__MODULE__, event, 5_000)

  @spec ingest(GenServer.server(), map()) :: {:ok, pos_integer()} | {:error, term()} | :drop
  def ingest(server, event), do: ingest(server, event, 5_000)

  @spec ingest(GenServer.server(), map(), timeout()) :: {:ok, pos_integer()} | {:error, term()} | :drop
  def ingest(server, event, timeout), do: GenServer.call(server, {:ingest, event}, timeout)

  @impl Aiur.Events.DurableConsumer.Source
  def subscribe(server, consumer), do: GenServer.call(server, {:subscribe, consumer})

  @impl Aiur.Events.DurableConsumer.Source
  def replay(server, cursor, limit), do: GenServer.call(server, {:replay, cursor, limit})

  @impl Aiur.Events.DurableConsumer.Source
  def position(%{"seq" => seq}), do: seq

  @impl true
  def init(opts) do
    with {:ok, journal_path, cursor_path} <- paths(opts),
         :ok <- Journal.prepare(Path.dirname(journal_path), journal_path),
         {:ok, records} <- replay_journal(journal_path),
         :ok <- validate_sequence(records) do
      exchange = Keyword.get(opts, :exchange)
      subscribe_to_exchange(exchange)
      cursor = load_cursor(cursor_path)

      {:ok,
       %{
         journal_path: journal_path,
         cursor_path: cursor_path,
         records: :queue.from_list(records),
         head: max(last_position(records), cursor),
         compacted_cursor: compacted_cursor(records, cursor),
         max_pending_events: Keyword.get(opts, :max_pending_events, configured_max_pending()),
         consumers: MapSet.new(),
         clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
         normalize_fun: Keyword.get(opts, :normalize_fun, &Event.normalize/2),
         append_fun: Keyword.get(opts, :append_fun, &Journal.append/2),
         reconcile_fun: Keyword.get(opts, :reconcile_fun, &Aiur.Journal.reconcile_ambiguous/3),
         alert_fun: Keyword.get(opts, :alert_fun, &ignore_alert/2),
         capacity_alerted?: false
       }}
    else
      {:error, reason} -> {:stop, {:journal_unavailable, reason}}
    end
  end

  @impl true
  def handle_call({:subscribe, consumer}, _from, state) when is_pid(consumer) do
    {:reply, :ok, %{state | consumers: MapSet.put(state.consumers, consumer)}}
  end

  def handle_call({:replay, cursor, limit}, _from, state) do
    {:reply, replay_window(:queue.to_list(state.records), cursor, limit), state}
  end

  def handle_call({:ingest, event}, _from, state) do
    {reply, state} = admit_internal(event, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:event, event}, state) do
    {_reply, state} = admit_internal(event, state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp admit_internal(event, state) do
    case state.normalize_fun.(event, state.clock.()) do
      {:ok, external_event} -> admit(external_event, state)
      :drop -> {:drop, state}
    end
  rescue
    error ->
      Logger.warning("outbound event normalization failed: #{Exception.message(error)}")
      {:drop, state}
  end

  defp admit(event, state) do
    cursor = load_cursor(state.cursor_path)

    with {:ok, state} <- compact_delivered(state, cursor),
         :ok <- capacity_available(state, cursor),
         record = %{"version" => 1, "seq" => state.head + 1, "event_id" => event["event_id"], "event" => event},
         :ok <- append_durably(state.journal_path, record, state) do
      Enum.each(state.consumers, &send(&1, {:durable_record, record}))
      state = maybe_resolve_capacity(%{state | records: :queue.in(record, state.records), head: record["seq"]})
      {{:ok, record["seq"]}, state}
    else
      {:error, :capacity_exhausted} ->
        state = alert_capacity(state)
        {{:error, :capacity_exhausted}, state}

      {:error, reason} ->
        state = alert_storage_failure(state, reason)
        {{:error, {:journal_unavailable, reason}}, state}
    end
  end

  defp capacity_available(state, cursor) do
    if state.head - cursor < state.max_pending_events, do: :ok, else: {:error, :capacity_exhausted}
  end

  defp compact_delivered(%{compacted_cursor: compacted_cursor} = state, cursor) when cursor <= compacted_cursor,
    do: {:ok, state}

  defp compact_delivered(state, cursor) do
    records = :queue.to_list(state.records)
    remaining = Enum.drop_while(records, &(position(&1) <= cursor))

    if length(remaining) == length(records) do
      {:ok, %{state | compacted_cursor: cursor}}
    else
      contents = Enum.map(remaining, &[Jason.encode!(&1), "\n"])

      case Journal.rewrite(state.journal_path, contents) do
        :ok -> {:ok, %{state | records: :queue.from_list(remaining), compacted_cursor: cursor}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp replay_window([], _cursor, _limit), do: {:ok, []}

  defp replay_window([first | _] = records, cursor, limit)
       when is_integer(cursor) and cursor >= 0 and is_integer(limit) and limit > 0 do
    oldest = position(first)
    head = position(List.last(records))

    if oldest > cursor + 1 or head < cursor do
      {:reset, oldest}
    else
      {:ok, records |> Enum.filter(&(position(&1) > cursor)) |> Enum.take(limit)}
    end
  end

  defp replay_window(_records, _cursor, _limit), do: {:error, :invalid_replay_window}

  defp replay_journal(path), do: Journal.replay(path, &validate_record/1)

  defp validate_record(
         %{
           "version" => 1,
           "seq" => seq,
           "event_id" => event_id,
           "event" => %{"event_id" => event_id}
         } = record
       )
       when is_integer(seq) and seq > 0 and is_binary(event_id) and event_id != "",
       do: {:ok, record}

  defp validate_record(_record), do: {:error, :invalid_outbound_record}

  defp append_durably(path, record, state) do
    case state.append_fun.(path, record) do
      :ok ->
        :ok

      {:error, append_reason} ->
        case state.reconcile_fun.(path, record["event_id"], &validate_record/1) do
          :accepted -> :ok
          :failed -> {:error, append_reason}
          {:ambiguous, reason} -> {:error, {:ambiguous_append, reason}}
        end
    end
  end

  defp validate_sequence([]), do: :ok

  defp validate_sequence(records) do
    positions = Enum.map(records, &position/1)

    if Enum.chunk_every(positions, 2, 1, :discard) |> Enum.all?(fn [left, right] -> right == left + 1 end),
      do: :ok,
      else: {:error, :non_dense_sequence}
  end

  defp subscribe_to_exchange(nil), do: :ok
  defp subscribe_to_exchange(exchange), do: Enum.each(@bindings, &Exchange.subscribe(&1, exchange))

  defp paths(opts) do
    case {Keyword.get(opts, :journal_path), Keyword.get(opts, :cursor_path)} do
      {journal, cursor} when is_binary(journal) and is_binary(cursor) -> {:ok, journal, cursor}
      {nil, nil} -> default_paths()
      _partial -> {:error, :incomplete_outbound_paths}
    end
  end

  defp default_paths do
    with {:ok, dir} <- Paths.outbound_events_state_dir() do
      {:ok, Path.join(dir, "events.ndjson"), Path.join(dir, "delivery-cursor.json")}
    end
  end

  defp load_cursor(path) do
    case JsonStore.read(path) do
      {:ok, %{"cursor" => cursor}} when is_integer(cursor) and cursor >= 0 -> cursor
      _missing_or_unreadable -> 0
    end
  end

  defp configured_max_pending, do: Aiur.Config.events_export().max_pending_events
  defp compacted_cursor([], cursor), do: cursor
  defp compacted_cursor([first | _], cursor), do: min(cursor, position(first) - 1)
  defp last_position([]), do: 0
  defp last_position(records), do: records |> List.last() |> position()

  defp alert_capacity(%{capacity_alerted?: true} = state), do: state

  defp alert_capacity(state) do
    message = "Outbound event delivery queue is full; new events are not being admitted."
    safe_alert(state.alert_fun, "system.outbound_events.queue.capacity", message, true)
    %{state | capacity_alerted?: true}
  end

  defp maybe_resolve_capacity(%{capacity_alerted?: false} = state), do: state

  defp maybe_resolve_capacity(state) do
    message = "Outbound event delivery queue has capacity again."
    safe_alert(state.alert_fun, "system.outbound_events.queue.capacity.resolved", message, false)
    %{state | capacity_alerted?: false}
  end

  defp alert_storage_failure(state, _reason) do
    message = "Outbound event delivery queue storage is unavailable."
    safe_alert(state.alert_fun, "system.outbound_events.queue.storage", message, true)
    state
  end

  defp safe_alert(alert_fun, topic, message, needs_attention) do
    _ = alert_fun.(topic, message: message, reason: message, needs_attention: needs_attention, severity: if(needs_attention, do: "warning", else: "info"))
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp ignore_alert(_topic, _opts), do: :ok
end

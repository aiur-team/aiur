defmodule Aiur.RunTelemetry.Writer do
  @moduledoc """
  Serializes versioned telemetry records into one append-only NDJSON stream.

  The writer owns a strictly increasing sequence within each daemon boot. A
  failed append advances the sequence anyway, making any later recovery gap
  visible to the offline reducer instead of silently reusing an identity.

  Admission control bounds the pending mailbox to a fixed number of *messages*
  (a `record_batch/3` cast counts as one message regardless of how many records
  it carries). Records refused at admission are counted and surfaced as a
  single `warning` record (`reason: :admission_overflow`) once the writer
  drains. Overflow uses a drop-newest policy, so all caller cast kinds share
  the same admission budget. `handle_info/2` events (subscribed GitHub
  anchors) bypass admission entirely and are always appended.

  The admission counter is discovered from the Writer process dictionary on
  each caller cast. That keeps named-server lookup restart-safe; replacing it
  with a persistent-term registry is intentionally deferred because this
  debug-only path would need explicit stale-pid cleanup.
  """

  use GenServer

  require Logger

  alias Aiur.Events.Exchange
  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.Lifecycle
  alias Aiur.RunTelemetry.Retention

  @external_event_patterns [
    "ticket.*.pr.opened",
    "ticket.*.pr.merged",
    "ticket.*.issue.commented",
    "ticket.*.pr.review_comment"
  ]

  @max_pending_casts 256
  @admission_key {__MODULE__, :pending_casts}

  # Atomics slots shared between callers and the writer process.
  @pending_index 1
  @dropped_index 2
  @overflow_logged_index 3

  @type server :: GenServer.server()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec record(server(), atom() | String.t(), map()) :: :ok
  def record(server, kind, attributes), do: record(server, kind, attributes, [])

  @spec record(server(), atom() | String.t(), map(), keyword()) :: :ok
  def record(server, kind, attributes, opts)
      when (is_atom(kind) or is_binary(kind)) and is_map(attributes) and is_list(opts) do
    timestamp = Keyword.get(opts, :timestamp, DateTime.utc_now())
    enqueue_cast(server, {:record, kind, attributes, timestamp})
    :ok
  catch
    :exit, _reason -> :ok
  end

  def record(_server, _kind, _attributes, _opts), do: :ok

  @doc false
  @spec record_batch(server(), [{atom() | String.t(), map()}], keyword()) :: :ok
  def record_batch(server, records, opts \\ []) when is_list(records) and is_list(opts) do
    timestamp = Keyword.get(opts, :timestamp, DateTime.utc_now())
    enqueue_cast(server, {:record_batch, records, timestamp})
    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec flush(server()) :: :ok
  def flush(server \\ __MODULE__) do
    GenServer.call(server, :flush)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    subscribe_external_events()

    path = Keyword.get(opts, :path, RunTelemetry.telemetry_file())
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    boot_id = Keyword.get_lazy(opts, :boot_id, &RunTelemetry.boot_id/0)
    retention = Keyword.get_lazy(opts, :retention, &RunTelemetry.telemetry_retention/0)

    case Retention.prune(path, retention |> Keyword.put(:now, clock.()) |> Keyword.put(:protected_boot_id, boot_id)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("run_telemetry retention_failed path=#{path} reason=#{inspect(reason)}")
    end

    state = %{
      path: path,
      boot_id: boot_id,
      sequence: 0,
      shared_sequence?: not Keyword.has_key?(opts, :boot_id),
      clock: clock,
      write_fun: Keyword.get(opts, :write_fun, &write_file/2),
      write_warning_emitted: false,
      retention: retention,
      bytes_since_prune: 0,
      prune_interval_bytes: prune_interval(retention),
      open_lifecycles: %{}
    }

    Process.put(@admission_key, :atomics.new(3, signed: false))

    attributes = %{
      event: :daemon_restart,
      daemon_pid: System.pid(),
      daemon_started_at: RunTelemetry.boot_started_at(),
      existing_records: existing_records?(path)
    }

    {:ok, append(state, :restart, attributes, clock.())}
  end

  @impl true
  def handle_cast({:record, kind, attributes, timestamp, admission}, state) do
    state = append(state, kind, attributes, timestamp)
    release_admission(admission)
    {:noreply, maybe_emit_overflow_marker(state, admission)}
  end

  def handle_cast({:record_batch, records, timestamp, admission}, state) do
    batch =
      Enum.flat_map(records, fn
        {kind, attributes} when is_map(attributes) -> [{kind, attributes, timestamp}]
        _other -> []
      end)

    state = append_many(state, batch)
    release_admission(admission)
    {:noreply, maybe_emit_overflow_marker(state, admission)}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:event, event}, state) when is_map(event) do
    case Lifecycle.external_anchor(event) do
      {:ok, attributes, timestamp} -> {:noreply, append(state, :lifecycle, attributes, timestamp)}
      :skip -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp append(state, kind, attributes, timestamp) do
    append_many(state, [{kind, attributes, timestamp}])
  end

  defp append_many(state, []), do: state

  defp append_many(state, records) do
    {state, contents} = encode_records(state, records)

    # Callers timestamp casts before enqueueing them. Reusing the triggering
    # event time keeps a rolled continuation ahead of later queued events.
    {_kind, _attributes, boundary_timestamp} = List.last(records)

    with :ok <- File.mkdir_p(Path.dirname(state.path)),
         :ok <- state.write_fun.(state.path, contents) do
      state = %{
        state
        | bytes_since_prune: state.bytes_since_prune + byte_size(contents),
          open_lifecycles: track_lifecycles(state.open_lifecycles, records),
          write_warning_emitted: false
      }

      maybe_prune(state, boundary_timestamp)
    else
      {:error, reason} -> warn_write_failure(state, reason)
    end
  rescue
    error -> warn_write_failure(state, Exception.message(error))
  catch
    kind, reason -> warn_write_failure(state, {kind, reason})
  end

  defp warn_write_failure(%{write_warning_emitted: true} = state, _reason), do: state

  defp warn_write_failure(state, reason) do
    Logger.warning("run_telemetry write_failed path=#{state.path} reason=#{inspect(reason)}")
    %{state | write_warning_emitted: true}
  end

  defp enqueue_cast(server, message) do
    with pid when is_pid(pid) <- server_pid(server),
         {:ok, counter} <- admission_counter(pid) do
      if admit?(counter) do
        GenServer.cast(pid, append_admission(message, counter))
      else
        note_overflow(counter)
      end
    end

    :ok
  end

  defp note_overflow(counter) do
    :atomics.add(counter, @dropped_index, 1)

    if :atomics.compare_exchange(counter, @overflow_logged_index, 0, 1) == :ok do
      Logger.warning(
        "run_telemetry admission_overflow cap=#{@max_pending_casts} messages; " <>
          "dropping records until the writer drains"
      )
    end

    :ok
  end

  # After the pending queue drains, surface any records dropped at admission as
  # one warning record so the offline reducer can see the gap. Resetting the
  # once-flag lets a later, distinct overload log again.
  defp maybe_emit_overflow_marker(state, counter) do
    with 0 <- :atomics.get(counter, @pending_index),
         dropped when dropped > 0 <- :atomics.exchange(counter, @dropped_index, 0) do
      :atomics.put(counter, @overflow_logged_index, 0)
      append(state, :warning, %{reason: :admission_overflow, dropped_count: dropped}, state.clock.())
    else
      _other -> state
    end
  end

  defp append_admission({:record, kind, attributes, timestamp}, admission),
    do: {:record, kind, attributes, timestamp, admission}

  defp append_admission({:record_batch, records, timestamp}, admission),
    do: {:record_batch, records, timestamp, admission}

  defp admission_counter(pid) do
    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         {@admission_key, counter} <- List.keyfind(dictionary, @admission_key, 0) do
      {:ok, counter}
    else
      _other -> :unavailable
    end
  end

  defp server_pid(server) when is_pid(server), do: server
  defp server_pid(server), do: GenServer.whereis(server)

  defp admit?(counter) do
    current = :atomics.get(counter, @pending_index)

    cond do
      current >= @max_pending_casts -> false
      :atomics.compare_exchange(counter, @pending_index, current, current + 1) == :ok -> true
      true -> admit?(counter)
    end
  end

  defp release_admission(counter), do: :atomics.sub(counter, @pending_index, 1)

  defp maybe_prune(%{prune_interval_bytes: nil} = state, _timestamp), do: state

  defp maybe_prune(%{bytes_since_prune: n, prune_interval_bytes: threshold} = state, _timestamp)
       when n < threshold,
       do: state

  defp maybe_prune(state, timestamp) do
    if segment_roll_required?(state) do
      roll_and_prune(state, timestamp)
    else
      prune_historical_boots(state)
    end
  rescue
    error ->
      Logger.warning("run_telemetry retention_raised path=#{state.path} reason=#{inspect(error)}")
      %{state | bytes_since_prune: 0}
  end

  defp roll_and_prune(state, timestamp) do
    # Roll the current segment: append a restart marker to close the current
    # segment so any data before this point is pruneable as a completed group.
    # The fresh restart marker re-anchors the current boot in the file, so the
    # subsequent prune (which does not protect any boot) leaves it parseable.
    # If the boundary write fails (sequence unchanged), skip pruning to avoid
    # cutting mid-segment without a clean group boundary.
    rolled = write_segment_boundary(state, timestamp)

    if rolled.sequence != state.sequence do
      opts = rolled.retention |> Keyword.put(:now, rolled.clock.())

      case Retention.prune(rolled.path, opts) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("run_telemetry retention_failed path=#{rolled.path} reason=#{inspect(reason)}")
      end
    end

    %{rolled | bytes_since_prune: 0}
  end

  defp prune_historical_boots(state) do
    opts = state.retention |> Keyword.put(:now, state.clock.()) |> Keyword.put(:protected_boot_id, state.boot_id)

    case Retention.prune(state.path, opts) do
      :ok ->
        %{state | bytes_since_prune: 0}

      {:error, reason} ->
        Logger.warning("run_telemetry retention_failed path=#{state.path} reason=#{inspect(reason)}")
        %{state | bytes_since_prune: 0}
    end
  end

  defp segment_roll_required?(state) do
    with max_bytes when is_integer(max_bytes) and max_bytes > 0 <- Keyword.get(state.retention, :max_bytes),
         {:ok, %{size: size}} <- File.stat(state.path) do
      size > max_bytes
    else
      _other -> false
    end
  end

  defp write_segment_boundary(state, timestamp) do
    {closing, reopening, open_lifecycles} = segment_lifecycle_records(state.open_lifecycles, timestamp)

    records =
      closing ++
        [
          {:restart,
           %{
             event: "segment_boundary",
             daemon_pid: System.pid(),
             daemon_started_at: RunTelemetry.boot_started_at(),
             existing_records: true
           }, timestamp}
        ] ++ reopening

    {rolled, contents} = encode_records(state, records)

    case state.write_fun.(state.path, contents) do
      :ok ->
        %{
          rolled
          | bytes_since_prune: state.bytes_since_prune + byte_size(contents),
            open_lifecycles: open_lifecycles
        }

      {:error, reason} ->
        Logger.warning("run_telemetry segment_roll_failed path=#{state.path} reason=#{inspect(reason)}")
        state
    end
  end

  # Default interval: max_bytes / 8, minimum 1 MiB. It can be overridden with
  # observability.telemetry_retention_prune_interval_bytes (or directly in
  # the retention keyword list for focused tests).
  defp prune_interval(retention) do
    case Keyword.get(retention, :prune_interval_bytes) do
      n when is_integer(n) and n > 0 ->
        n

      _other ->
        case Keyword.get(retention, :max_bytes) do
          bytes when is_integer(bytes) and bytes > 0 -> max(div(bytes, 8), 1024 * 1024)
          _other -> nil
        end
    end
  end

  defp write_file(path, contents), do: File.write(path, contents, [:append])

  defp existing_records?(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 -> true
      _other -> false
    end
  end

  defp subscribe_external_events do
    Enum.each(@external_event_patterns, &Exchange.subscribe/1)
    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp next_sequence(%{shared_sequence?: true}), do: RunTelemetry.next_sequence()
  defp next_sequence(state), do: state.sequence + 1

  defp maybe_mark_writer_restart(%{shared_sequence?: true}, kind, attributes, sequence)
       when kind in [:restart, "restart"] and sequence > 1 do
    if Map.get(attributes, :event) in [:daemon_restart, "daemon_restart"] do
      Map.put(attributes, :event, :telemetry_writer_restart)
    else
      attributes
    end
  end

  defp maybe_mark_writer_restart(_state, _kind, attributes, _sequence), do: attributes

  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind) when is_binary(kind), do: kind
  defp normalize_kind(kind), do: inspect(kind)

  defp normalize_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp normalize_timestamp(timestamp) when is_binary(timestamp), do: timestamp
  defp normalize_timestamp(_timestamp), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp encode_records(state, records) do
    {state, lines} =
      Enum.reduce(records, {state, []}, fn {kind, attributes, timestamp}, {state, lines} ->
        sequence = next_sequence(state)
        attributes = maybe_mark_writer_restart(state, kind, attributes, sequence)

        envelope = %{
          schema_version: RunTelemetry.schema_version(),
          kind: normalize_kind(kind),
          timestamp: normalize_timestamp(timestamp),
          recorded_at: normalize_timestamp(state.clock.()),
          boot_id: state.boot_id,
          sequence: sequence,
          record_id: "#{state.boot_id}:#{sequence}",
          attributes: attributes
        }

        {:ok, encoded} = Jason.encode(Aiur.JSONSafe.normalize(envelope))
        {%{state | sequence: sequence}, [[encoded, "\n"] | lines]}
      end)

    {state, lines |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp track_lifecycles(open_lifecycles, records) do
    Enum.reduce(records, open_lifecycles, fn {kind, attributes, timestamp}, open_lifecycles ->
      case lifecycle_key(kind, attributes) do
        {:start, key} -> Map.put(open_lifecycles, key, {attributes, timestamp})
        {:end, key} -> Map.delete(open_lifecycles, key)
        :skip -> open_lifecycles
      end
    end)
  end

  defp segment_lifecycle_records(open_lifecycles, timestamp) do
    open_lifecycles
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.reduce({[], [], %{}}, fn {key, {attributes, _started_at}}, {closing, reopening, continued} ->
      closing_attributes =
        attributes
        |> put_attribute(:boundary, "end")
        |> put_attribute(:duration_status, "segmented")
        |> put_attribute(:segment_continuation, "close")

      opening_attributes =
        attributes
        |> put_attribute(:boundary, "start")
        |> put_attribute(:duration_status, "segmented")
        |> put_attribute(:segment_continuation, "open")

      {
        [{:lifecycle, closing_attributes, timestamp} | closing],
        [{:lifecycle, opening_attributes, timestamp} | reopening],
        Map.put(continued, key, {opening_attributes, timestamp})
      }
    end)
    |> then(fn {closing, reopening, continued} -> {Enum.reverse(closing), Enum.reverse(reopening), continued} end)
  end

  defp lifecycle_key(kind, attributes) when kind in [:lifecycle, "lifecycle"] and is_map(attributes) do
    case attribute_value(attributes, :boundary) do
      boundary when boundary in [:start, "start"] -> {:start, lifecycle_pair_key(attributes)}
      boundary when boundary in [:end, "end"] -> {:end, lifecycle_pair_key(attributes)}
      _other -> :skip
    end
  end

  defp lifecycle_key(_kind, _attributes), do: :skip

  defp lifecycle_pair_key(attributes) do
    {
      attribute_value(attributes, :attempt_id),
      attribute_value(attributes, :event),
      attribute_value(attributes, :operation_id)
    }
  end

  defp attribute_value(attributes, key), do: Map.get(attributes, key) || Map.get(attributes, Atom.to_string(key))

  defp put_attribute(attributes, key, value) do
    attributes
    |> Map.delete(Atom.to_string(key))
    |> Map.put(key, value)
  end
end

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
  alias Aiur.RunTelemetry.{Retention, Summaries}
  alias Aiur.RunTelemetry.Writer.Encoding
  alias Aiur.RunTelemetry.Writer.Retention, as: WriterRetention

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
      prune_interval_bytes: WriterRetention.prune_interval(retention),
      open_lifecycles: %{},
      carried_points: %{}
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

  # Best-effort shutdown materialization: write the final per-boot run summary
  # and any build rollups so the dashboard can serve prior boots without a raw
  # full-stream parse. Fails open (and is regenerable by analytics/reduce) when
  # the reducer or state node is unavailable.
  @impl true
  def terminate(_reason, _state) do
    case Summaries.materialize() do
      {:ok, _output} -> :ok
      {:error, reason} -> Logger.info("run_telemetry summary_shutdown_failed reason=#{inspect(reason)}")
    end

    :ok
  end

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
    {state, contents, encoded_records} = Encoding.encode_records(state, records)

    with :ok <- File.mkdir_p(Path.dirname(state.path)),
         :ok <- state.write_fun.(state.path, contents) do
      state = %{
        state
        | bytes_since_prune: state.bytes_since_prune + byte_size(contents),
          open_lifecycles: Encoding.track_lifecycles(state.open_lifecycles, encoded_records),
          carried_points: Encoding.track_carried_points(state.carried_points, encoded_records),
          write_warning_emitted: false
      }

      WriterRetention.maybe_prune(state)
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
end

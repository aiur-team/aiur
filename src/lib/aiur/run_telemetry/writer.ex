defmodule Aiur.RunTelemetry.Writer do
  @moduledoc """
  Serializes versioned telemetry records into one append-only NDJSON stream.

  The writer owns a strictly increasing sequence within each daemon boot. A
  failed append advances the sequence anyway, making any later recovery gap
  visible to the offline reducer instead of silently reusing an identity.
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
    GenServer.cast(server, {:record, kind, attributes, timestamp})
    :ok
  catch
    :exit, _reason -> :ok
  end

  def record(_server, _kind, _attributes, _opts), do: :ok

  @doc false
  @spec record_batch(server(), [{atom() | String.t(), map()}], keyword()) :: :ok
  def record_batch(server, records, opts \\ []) when is_list(records) and is_list(opts) do
    timestamp = Keyword.get(opts, :timestamp, DateTime.utc_now())
    GenServer.cast(server, {:record_batch, records, timestamp})
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
      write_warning_emitted: false
    }

    attributes = %{
      event: :daemon_restart,
      daemon_pid: System.pid(),
      daemon_started_at: RunTelemetry.boot_started_at(),
      existing_records: existing_records?(path)
    }

    {:ok, append(state, :restart, attributes, clock.())}
  end

  @impl true
  def handle_cast({:record, kind, attributes, timestamp}, state) do
    {:noreply, append(state, kind, attributes, timestamp)}
  end

  def handle_cast({:record_batch, records, timestamp}, state) do
    batch =
      Enum.flat_map(records, fn
        {kind, attributes} when is_map(attributes) -> [{kind, attributes, timestamp}]
        _other -> []
      end)

    {:noreply, append_many(state, batch)}
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

    contents = lines |> Enum.reverse() |> IO.iodata_to_binary()

    with :ok <- File.mkdir_p(Path.dirname(state.path)),
         :ok <- File.write(state.path, contents, [:append]) do
      %{state | write_warning_emitted: false}
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
    Map.put(attributes, :event, :telemetry_writer_restart)
  end

  defp maybe_mark_writer_restart(_state, _kind, attributes, _sequence), do: attributes

  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind) when is_binary(kind), do: kind
  defp normalize_kind(kind), do: inspect(kind)

  defp normalize_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp normalize_timestamp(timestamp) when is_binary(timestamp), do: timestamp
  defp normalize_timestamp(_timestamp), do: DateTime.utc_now() |> DateTime.to_iso8601()
end

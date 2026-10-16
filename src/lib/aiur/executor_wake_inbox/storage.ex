defmodule Aiur.ExecutorWakeInbox.Storage do
  @moduledoc false

  require Logger

  alias Aiur.ExecutorWakeInbox.Recovery
  alias Aiur.Fs
  alias Aiur.Journal
  alias Aiur.JsonStore
  alias Aiur.Signal

  @doc false
  @spec unread_records(map()) :: {:ok, [map()]} | {:error, term()}
  def unread_records(state) do
    cursor = current_cursor(state)

    with {:ok, records} <- durable_records(state) do
      {:ok, Enum.filter(records, &(&1["wake_id"] > cursor))}
    end
  end

  @doc false
  @spec durable_records(map()) :: {:ok, [map()]} | {:error, term()}
  def durable_records(state) do
    case Journal.replay(state.path, &validate_record/1) do
      {:ok, records, nil} -> {:ok, records}
      {:ok, _records, corruption} -> {:error, corruption}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_record(%{"wake_id" => wake_id, "event_id" => event_id, "topic" => topic} = record)
       when is_integer(wake_id) and wake_id > 0 and (is_integer(event_id) or is_nil(event_id)) and is_binary(topic),
       do: {:ok, record}

  defp validate_record(_record), do: {:error, :invalid_executor_wake}

  @doc false
  @spec append_new_records(Path.t(), [map()]) :: :ok | {:error, term()}
  def append_new_records(path, records) do
    with {:ok, durable_ids} <- durable_wake_ids(path) do
      records
      |> Enum.reject(&MapSet.member?(durable_ids, &1["wake_id"]))
      |> Enum.reduce_while(:ok, &append_record(path, &1, &2))
    end
  end

  defp append_record(path, record, :ok) do
    case Journal.append(path, record) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp durable_wake_ids(path) do
    case Journal.replay(path, &validate_record/1) do
      {:ok, records, nil} -> {:ok, MapSet.new(records, & &1["wake_id"])}
      {:ok, _records, corruption} -> {:error, corruption}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec persist_pending(Path.t(), map()) :: :ok
  def persist_pending(path, pending) do
    encoded = Map.new(pending, fn {{topic_class, ticket}, record} -> {Jason.encode!([topic_class, ticket]), record} end)
    JsonStore.write!(path, encoded)
  end

  @doc false
  @spec read_pending(Path.t()) :: {:ok, map()} | {:error, term()}
  def read_pending(path) do
    case JsonStore.read(path, %{}) do
      {:ok, %{} = encoded} ->
        decode_pending(encoded)

      {:ok, _wrong_shape} ->
        {:error, :invalid_executor_wake_pending_store}

      {:error, reason} ->
        {:error, {:executor_wake_pending_store_unavailable, reason}}
    end
  end

  defp decode_pending(encoded) do
    Enum.reduce_while(encoded, {:ok, %{}}, fn {encoded_key, record}, {:ok, pending} ->
      with {:ok, key} <- decode_pending_key(encoded_key),
           false <- Map.has_key?(pending, key),
           {:ok, record} <- validate_pending_record(key, record) do
        {:cont, {:ok, Map.put(pending, key, record)}}
      else
        _invalid -> {:halt, {:error, :invalid_executor_wake_pending_store}}
      end
    end)
  end

  defp decode_pending_key(encoded_key) when is_binary(encoded_key) do
    case Jason.decode(encoded_key) do
      {:ok, [topic_class, ticket]}
      when is_binary(topic_class) and (is_binary(ticket) or is_nil(ticket)) ->
        {:ok, {topic_class, ticket}}

      _invalid ->
        :error
    end
  end

  defp decode_pending_key(_encoded_key), do: :error

  defp validate_pending_record({topic_class, ticket}, record) do
    with {:ok, record} <- validate_record(record),
         true <- record["topic_class"] == topic_class and record["ticket"] == ticket do
      {:ok, record}
    else
      _invalid -> :error
    end
  end

  # A corrupt line stops the replay at the good prefix. Rather than refuse to
  # start forever (and loop the supervisor), keep the bad file as evidence and
  # restart on the prefix; any other replay error still stops the inbox.
  @doc false
  @spec journal_summary(Path.t(), map(), Path.t(), function()) :: {:ok, map()} | {:error, term()}
  def journal_summary(path, pending, cursor_path, alert_fun) do
    with {:ok, records, quarantined_max} <- Recovery.replay_or_quarantine(path, &validate_record/1, alert_fun) do
      cursor = read_cursor(cursor_path)
      durable_ids = Enum.map(records, & &1["wake_id"])
      pending_ids = pending |> Map.values() |> Enum.map(& &1["wake_id"])

      {:ok,
       %{
         next_wake_id: Enum.max([cursor, quarantined_max | durable_ids ++ pending_ids]) + 1,
         cursor: cursor,
         pending_count: Enum.count(records, &(&1["wake_id"] > cursor))
       }}
    end
  end

  defp read_cursor(path) do
    case JsonStore.read(path, %{}) do
      {:ok, %{"last_seen_wake_id" => id}} when is_integer(id) -> id
      _ -> 0
    end
  end

  # The journal, cursor and pending files live under the repository state root,
  # not under a process, so every Executor daemon on this host and repository
  # shares them. A peer that acknowledges wakes advances the very same cursor
  # file while this process still holds the value it cached at boot. Caching is
  # still worth keeping for the write path, so the cached value is treated as a
  # lower bound rather than the truth: reads take the newer of cache and disk,
  # which observes a peer's advance and still cannot be rewound by a stale file.
  @doc false
  @spec current_cursor(map()) :: non_neg_integer()
  def current_cursor(state), do: max(state.cursor, read_cursor(state.cursor_path))

  @doc false
  @spec refresh_cursor(map()) :: map()
  def refresh_cursor(state), do: %{state | cursor: current_cursor(state)}

  @doc false
  @spec advance_cursor(map(), [map()]) :: map()
  def advance_cursor(state, records) do
    cursor = Enum.max([current_cursor(state) | Enum.map(records, & &1["wake_id"])])
    :ok = JsonStore.write!(state.cursor_path, %{"last_seen_wake_id" => cursor})
    %{state | cursor: cursor}
  end

  # Recording is unconditional now, so an unattended run appends wake records
  # that nobody will ever acknowledge. Dropping only consumed records left the
  # ledger unbounded in exactly that case, which is the growth #1661 is about.
  # The retained set is therefore capped at `max_records` outright: consumed
  # records are evicted first and only then the oldest unread, so the bound
  # holds with or without a consumer.
  #
  # Evicting an unread record loses a wake, so it is never silent — it is logged
  # with the count and the id range, and the durable cursor is advanced past the
  # dropped range so a consumer's next read is honest about where the stream now
  # begins rather than replaying a gap it cannot fill.
  @doc false
  @spec trim_consumed(map()) :: map()
  def trim_consumed(state) do
    case Journal.replay(state.path, &validate_record/1) do
      {:ok, records, nil} -> trim_records(state, records)
      {:ok, _records, corruption} -> Recovery.trim_failed(state, corruption)
      {:error, reason} -> Recovery.trim_failed(state, reason)
    end
  end

  defp trim_records(state, records) do
    {unread, consumed} = Enum.split_with(records, &(&1["wake_id"] > state.cursor))
    # Hysteresis: past the cap, trim to 80% so the rename happens once per 20% of the cap, not per append (#4166).
    limit = if length(records) > state.max_records, do: div(state.max_records * 4, 5), else: state.max_records
    retained_unread = Enum.take(unread, -limit)
    retained = Enum.take(consumed, -max(limit - length(retained_unread), 0)) ++ retained_unread

    state =
      if length(retained) < length(records) do
        contents = Enum.map(retained, &[Jason.encode!(&1), "\n"])

        case Fs.atomic_write(state.path, contents, fsync: true, mode: 0o600) do
          :ok -> state
          {:error, reason} -> Recovery.trim_failed(state, reason)
        end
      else
        state
      end

    cursor = report_dropped_unread(state, unread -- retained_unread)
    %{state | cursor: cursor, pending_count: length(retained_unread)}
  end

  defp report_dropped_unread(state, []), do: state.cursor

  defp report_dropped_unread(state, dropped) do
    ids = Enum.map(dropped, & &1["wake_id"])
    cursor = Enum.max(ids)
    :ok = JsonStore.write!(state.cursor_path, %{"last_seen_wake_id" => cursor})

    message =
      "Executor wake ledger overflowed its #{state.max_records}-record bound; " <>
        "#{length(dropped)} unread wakes (ids #{Enum.min(ids)}-#{Enum.max(ids)}) were evicted and will never be delivered."

    Logger.warning(
      "aiur_executor_wake_inbox phase=unread_evicted count=#{length(dropped)} " <>
        "first_wake_id=#{Enum.min(ids)} last_wake_id=#{Enum.max(ids)} max_records=#{state.max_records}"
    )

    safe_overflow_alert(message)
    cursor
  end

  # Losing a wake is exactly the class of event an operator must be told about;
  # a daemon log line is effectively silent. The alert never carries record
  # content, only counts and ids, so the identifier-only boundary holds.
  defp safe_overflow_alert(message) do
    if Application.get_env(:aiur, :executor_wake_overflow_alerts?, true) do
      safe_alert("executor.wakes.overflow", message, needs_attention: false, severity: "warning")
    end

    :ok
  end

  @doc false
  @spec safe_alert(String.t(), String.t(), keyword()) :: :ok
  def safe_alert(name, message, opts) do
    _ = Signal.agent_alert(name, message, opts)
    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end
end

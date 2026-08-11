defmodule Aiur.Webhooks.DeliveryLog do
  @moduledoc """
  Durable, bounded idempotency state for inbound GitHub webhook deliveries.

  GitHub webhooks are at-least-once. A slow, non-2xx, or >10s response makes
  GitHub retry the same delivery, the operator can redeliver by hand, and plain
  network faults produce duplicates carrying no signal that they are duplicates.
  This store is the first line of defence: a delivery, a semantic event, or an
  ordering watermark is *claimed* here before any handler runs, and a repeat
  claim is reported as a duplicate.

  ## Two operations

  * `claim/3` — exactly-once admission for an opaque id (`X-GitHub-Delivery`,
    or a semantic event key derived by `Aiur.Webhooks.EventKey`). The first
    claim answers `:new`, every later claim inside the retention window answers
    `{:duplicate, recorded_at_ms}`.
  * `advance/4` — monotonic watermark for a scope (for example one issue's
    label state). An older or equal position answers `{:stale, current}`, so an
    out-of-order redelivery cannot re-apply superseded state.

  ## Retention window and why it is 72 hours

  GitHub retries a failed delivery with backoff for up to three days, so any id
  younger than that can legitimately arrive again. `@retention_ms` is therefore
  72 hours: long enough that the whole automatic retry envelope is covered, and
  short enough that the on-disk set stays small. Manual redelivery from the
  App's Advanced tab can reach further back than that, but it is an explicit
  operator action on a delivery the operator wants re-run; the idempotent
  handlers behind this store are the correct defence there, not an unbounded
  set.

  Eviction is **by age, not by count**. A burst of redeliveries appends many
  young entries and evicts nothing, so entries still inside the window survive
  the burst. `@max_entries` exists only as a memory backstop far above real
  volume; crossing it evicts the oldest entries *and* raises an alert, because
  at that point duplicate protection is measurably degraded rather than
  silently weakened.

  ## Surviving restart

  The claim set is persisted as one fsynced newline-delimited JSON record per
  accepted claim, in the daemon-private state directory, and replayed at boot
  with expired records dropped. Daemon restarts are routine here, so an
  in-memory-only set would be empty exactly when a redelivery is most likely
  (GitHub retries a delivery the crashed daemon never acknowledged).

  Claims are recorded **before** the handler runs. A crash between the claim
  and the side effect therefore loses that delivery rather than double-applying
  it; the reconciliation sweep (W-5) is what recovers a lost delivery, and this
  ordering keeps the failure mode on the side reconciliation can repair.

  ## Failing open

  Every fault in this store — unresolvable state directory, unwritable file,
  corrupt stream, dead process — degrades to "let the delivery through" and
  reports it through `health/1` plus an alert. Dropping real events is worse
  than processing a duplicate, because handlers are individually idempotent.
  """

  use GenServer

  require Logger

  alias Aiur.{Alerts, Config, DecisionLog, Fs}

  @filename "webhook_deliveries.ndjson"
  @retention_ms 72 * 60 * 60 * 1000
  @sweep_interval_ms 5 * 60 * 1000
  @max_entries 200_000
  @compaction_floor 1_000
  @call_timeout 30_000
  @max_key_bytes 512

  @type claim_result :: :new | {:duplicate, integer()}
  @type advance_result :: :ok | {:stale, integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Claims `id` under `scope` exactly once inside the retention window.

  Answers `:new` the first time and `{:duplicate, recorded_at_ms}` for every
  repeat. Any store fault answers `:new`, so a broken store never swallows a
  delivery.
  """
  @spec claim(atom(), term(), GenServer.server()) :: claim_result()
  def claim(scope, id, server \\ __MODULE__) do
    case entry_key(scope, id) do
      nil -> :new
      key -> call(server, {:claim, key}, :new)
    end
  end

  @doc """
  Advances the watermark for `scope`/`id` to `position`.

  Answers `:ok` when `position` is strictly newer than the recorded one (or
  none is recorded), and `{:stale, current}` when the caller is holding a
  superseded payload.
  """
  @spec advance(atom(), term(), integer(), GenServer.server()) :: advance_result()
  def advance(scope, id, position, server \\ __MODULE__) when is_integer(position) do
    case entry_key(scope, id) do
      nil -> :ok
      key -> call(server, {:advance, key, position}, :ok)
    end
  end

  @doc """
  Returns the recorded value for `scope`/`id`, or `nil` when absent or expired.
  """
  @spec lookup(atom(), term(), GenServer.server()) :: integer() | nil
  def lookup(scope, id, server \\ __MODULE__) do
    case entry_key(scope, id) do
      nil -> nil
      key -> call(server, {:lookup, key}, nil)
    end
  end

  @doc """
  Returns `:writable`, or a tagged reason when persistence is degraded.
  """
  @spec health(GenServer.server()) :: :writable | tuple()
  def health(server \\ __MODULE__), do: call(server, :health, :writable)

  @doc """
  Returns the number of live (unexpired) entries currently retained.
  """
  @spec size(GenServer.server()) :: non_neg_integer()
  def size(server \\ __MODULE__), do: call(server, :size, 0)

  @doc """
  Runs one eviction sweep synchronously. Exposed for tests and for callers that
  want deterministic pruning rather than waiting for the periodic tick.
  """
  @spec sweep(GenServer.server()) :: :ok
  def sweep(server \\ __MODULE__), do: call(server, :sweep, :ok)

  @doc """
  The retention window in milliseconds.
  """
  @spec retention_ms() :: pos_integer()
  def retention_ms, do: @retention_ms

  defp call(server, message, fallback) do
    GenServer.call(server, message, @call_timeout)
  catch
    kind, reason ->
      Logger.warning("aiur_webhook_delivery_log phase=call_failed error=#{inspect({kind, reason})}")
      fallback
  end

  defp entry_key(scope, id) when is_atom(scope) and is_binary(id) and id != "", do: bound("#{scope}:#{id}")
  defp entry_key(scope, id) when is_atom(scope) and is_integer(id), do: "#{scope}:#{id}"
  defp entry_key(_scope, _id), do: nil

  # Semantic keys are built from payload fields (a ref name, for one), so their
  # length is not ours to assume. Keeping every record small bounds the file as
  # well as the map, and a digest stays collision-safe as a dedupe key.
  defp bound(key) when byte_size(key) <= @max_key_bytes, do: key

  defp bound(key) do
    digest = :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower)
    binary_part(key, 0, @max_key_bytes) <> ":sha256:" <> digest
  end

  @impl true
  def init(opts) do
    settings = settings(opts)

    state =
      case state_dir(opts) do
        {:ok, dir} -> boot(dir, settings)
        {:error, reason} -> unavailable_state(nil, settings, {:path_unresolved, reason})
      end

    schedule_sweep(state)
    {:ok, state}
  end

  defp settings(opts) do
    %{
      append_fun: Keyword.get(opts, :append_fun, &DecisionLog.append/2),
      compact_fun: Keyword.get(opts, :compact_fun, &compact_log/2),
      sync_fun: Keyword.get(opts, :filesystem_sync_fun, &Fs.sync_filesystem/0),
      alert_fun: Keyword.get(opts, :alert_fun, &Alerts.emit_custom/3),
      clock_fun: Keyword.get(opts, :clock_fun, fn -> System.system_time(:millisecond) end),
      retention_ms: positive(opts, :retention_ms, @retention_ms),
      sweep_interval_ms: positive(opts, :sweep_interval_ms, @sweep_interval_ms),
      max_entries: positive(opts, :max_entries, @max_entries),
      compaction_floor: positive(opts, :compaction_floor, @compaction_floor)
    }
  end

  defp positive(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp state_dir(opts) do
    case Keyword.get(opts, :state_dir) do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> Config.Paths.decision_state_dir()
    end
  end

  defp boot(dir, settings) do
    path = Path.join(dir, @filename)

    case DecisionLog.prepare(dir, path, settings.sync_fun) do
      :ok -> replay(path, settings)
      {:error, reason} -> unavailable_state(path, settings, {:directory_unavailable, reason})
    end
  end

  defp replay(path, settings) do
    case DecisionLog.replay(path, &decode_record/1) do
      {:ok, records, corruption} ->
        path
        |> base_state(settings)
        |> Map.put(:record_count, length(records))
        |> load_records(records)
        |> apply_corruption(corruption)
        |> evict()
        |> maybe_compact()

      {:error, reason} ->
        unavailable_state(path, settings, {:replay_failed, reason})
    end
  end

  defp base_state(path, settings) do
    settings
    |> Map.drop([:sync_fun])
    |> Map.merge(%{
      path: path,
      entries: %{},
      record_count: 0,
      writable?: true,
      health: :writable,
      overflowed?: false
    })
  end

  defp load_records(state, records) do
    entries = Map.new(records, fn record -> {record.key, %{recorded_at: record.recorded_at, value: record.value}} end)
    %{state | entries: entries}
  end

  defp decode_record(%{"key" => key, "recorded_at" => recorded_at} = record)
       when is_binary(key) and key != "" and is_integer(recorded_at) do
    case Map.get(record, "value") do
      value when is_integer(value) or is_nil(value) ->
        {:ok, %{key: key, recorded_at: recorded_at, value: value}}

      other ->
        {:error, {:invalid_value, other}}
    end
  end

  defp decode_record(record), do: {:error, {:invalid_record, record}}

  defp apply_corruption(state, nil), do: state

  defp apply_corruption(state, {:corrupt, line, reason}) do
    Logger.error("aiur_webhook_delivery_log phase=corruption path=#{state.path} line=#{line} reason=#{inspect(reason)}")

    emit_alert(
      state,
      "webhook_delivery_log.corrupted",
      "Webhook delivery dedupe log is corrupt at #{state.path} line #{line} (#{inspect(reason)}); duplicate deliveries before that line may be reprocessed."
    )

    %{state | writable?: false, health: {:corrupt, line, reason}}
  end

  defp unavailable_state(path, settings, reason) do
    Logger.error("aiur_webhook_delivery_log phase=unavailable reason=#{inspect(reason)}")

    state =
      path
      |> base_state(settings)
      |> Map.merge(%{writable?: false, health: {:unavailable, reason}})

    emit_alert(
      state,
      "webhook_delivery_log.unavailable",
      "Webhook delivery dedupe log is unavailable (#{inspect(reason)}); deliveries are processed without restart-durable duplicate protection."
    )

    state
  end

  @impl true
  def handle_call({:claim, key}, _from, state) do
    now = state.clock_fun.()

    case live_entry(state, key, now) do
      %{recorded_at: recorded_at} ->
        {:reply, {:duplicate, recorded_at}, state}

      nil ->
        {:reply, :new, record(state, key, nil, now)}
    end
  end

  def handle_call({:advance, key, position}, _from, state) do
    now = state.clock_fun.()

    case live_entry(state, key, now) do
      %{value: current} when is_integer(current) and current >= position ->
        {:reply, {:stale, current}, state}

      _absent_or_older ->
        {:reply, :ok, record(state, key, position, now)}
    end
  end

  def handle_call({:lookup, key}, _from, state) do
    case live_entry(state, key, state.clock_fun.()) do
      %{value: value} -> {:reply, value, state}
      nil -> {:reply, nil, state}
    end
  end

  def handle_call(:health, _from, state), do: {:reply, state.health, state}

  def handle_call(:size, _from, state) do
    swept = evict(state)
    {:reply, map_size(swept.entries), swept}
  end

  def handle_call(:sweep, _from, state), do: {:reply, :ok, state |> evict() |> maybe_compact()}

  @impl true
  def handle_info(:sweep, state) do
    swept = state |> evict() |> maybe_compact()
    schedule_sweep(swept)
    {:noreply, swept}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule_sweep(state), do: Process.send_after(self(), :sweep, state.sweep_interval_ms)

  defp live_entry(state, key, now) do
    case Map.get(state.entries, key) do
      %{recorded_at: recorded_at} = entry when now - recorded_at < state.retention_ms -> entry
      _expired_or_absent -> nil
    end
  end

  defp record(state, key, value, now) do
    entries = Map.put(state.entries, key, %{recorded_at: now, value: value})

    state
    |> Map.put(:entries, entries)
    |> persist(%{"key" => key, "recorded_at" => now, "value" => value})
    |> enforce_ceiling(now)
  end

  # A degraded store keeps deduping in memory for the rest of this run: it is
  # strictly better than nothing, and it is exactly the durability the module
  # doc says is lost across a restart.
  defp persist(%{writable?: false} = state, _record), do: state

  defp persist(state, record) do
    case state.append_fun.(state.path, record) do
      :ok ->
        %{state | record_count: state.record_count + 1, health: :writable}

      {:error, reason} ->
        Logger.warning("aiur_webhook_delivery_log phase=append_failed reason=#{inspect(reason)}")

        state = %{state | writable?: false, health: {:append_failed, reason}}

        emit_alert(
          state,
          "webhook_delivery_log.unavailable",
          "Webhook delivery dedupe log append failed (#{inspect(reason)}); duplicate protection no longer survives restart."
        )

        state
    end
  end

  # Age is the only ordinary eviction rule, so a burst of redeliveries inside
  # the window evicts nothing. The ceiling below is a memory backstop, and
  # crossing it is loud rather than silent.
  defp evict(state) do
    now = state.clock_fun.()
    cutoff = now - state.retention_ms

    entries = Map.filter(state.entries, fn {_key, %{recorded_at: recorded_at}} -> recorded_at > cutoff end)

    %{state | entries: entries}
  end

  defp enforce_ceiling(state, now) do
    overflow = map_size(state.entries) - state.max_entries

    if overflow > 0 do
      state |> drop_oldest(overflow) |> alert_overflow(now)
    else
      state
    end
  end

  defp drop_oldest(state, overflow) do
    dropped =
      state.entries
      |> Enum.sort_by(fn {_key, %{recorded_at: recorded_at}} -> recorded_at end)
      |> Enum.take(overflow)
      |> Enum.map(fn {key, _entry} -> key end)

    %{state | entries: Map.drop(state.entries, dropped)}
  end

  defp alert_overflow(%{overflowed?: true} = state, _now), do: state

  defp alert_overflow(state, _now) do
    Logger.error("aiur_webhook_delivery_log phase=ceiling_exceeded max_entries=#{state.max_entries}")

    emit_alert(
      state,
      "webhook_delivery_log.ceiling_exceeded",
      "Webhook delivery dedupe log exceeded #{state.max_entries} live entries; the oldest entries were evicted before their retention window expired and duplicate protection is degraded."
    )

    %{state | overflowed?: true}
  end

  # The stream is append-only, so expired and superseded records accumulate.
  # Rewriting once the record count outgrows the live set keeps the file
  # proportional to what is actually retained.
  defp maybe_compact(%{writable?: false} = state), do: state

  defp maybe_compact(state) do
    live = map_size(state.entries)

    if state.record_count > max(2 * live, state.compaction_floor) do
      compact(state)
    else
      state
    end
  end

  defp compact(state) do
    records =
      Enum.map(state.entries, fn {key, entry} ->
        %{"key" => key, "recorded_at" => entry.recorded_at, "value" => entry.value}
      end)

    case state.compact_fun.(state.path, records) do
      :ok ->
        %{state | record_count: length(records), health: :writable}

      {:error, reason} ->
        Logger.warning("aiur_webhook_delivery_log phase=compaction_failed reason=#{inspect(reason)}")
        %{state | writable?: false, health: {:compaction_failed, reason}}
    end
  rescue
    error -> %{state | writable?: false, health: {:compaction_failed, {:exception, Exception.message(error)}}}
  catch
    :exit, reason -> %{state | writable?: false, health: {:compaction_failed, {:exit, reason}}}
  end

  defp compact_log(path, records) do
    with :ok <- regular_log?(path) do
      contents = Enum.map(records, &[Jason.encode!(&1), "\n"])
      Fs.atomic_write(path, contents, fsync: true, mode: 0o600)
    end
  end

  defp regular_log?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:symlink_rejected, path}}
      {:ok, %File.Stat{}} -> {:error, {:not_a_file, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_alert(state, topic, message) do
    alert_fun = state.alert_fun
    _ = alert_fun.(topic, message, needs_attention: true, severity: "warning", reason: message)
    :ok
  rescue
    error -> Logger.warning("aiur_webhook_delivery_log phase=alert_failed error=#{Exception.message(error)}")
  catch
    kind, reason -> Logger.warning("aiur_webhook_delivery_log phase=alert_failed error=#{inspect({kind, reason})}")
  end
end

defmodule Aiur.RecentMergeStore do
  @moduledoc """
  Single-writer store for bounded recent repository merges.

  Every accepted snapshot is fsynced before the in-memory projection changes
  or the observability dashboard is notified. The newest 100 merge projections
  are retained, and the append stream is atomically compacted before it can
  exceed 200 records. Replay serves the validated prefix but makes the store
  read-only on interior corruption.
  """

  use GenServer

  require Logger

  alias Aiur.{Alerts, Config, DecisionLog, Fs, RecentMerge}
  alias AiurWeb.ObservabilityPubSub

  @filename "recent_merges.ndjson"
  @retention_limit 100
  @compaction_record_limit 200

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec upsert(RecentMerge.t(), GenServer.server()) ::
          {:ok, %{status: :accepted | :duplicate, merge: RecentMerge.t()}} | {:error, term()}
  def upsert(%RecentMerge{} = merge, server \\ __MODULE__) do
    GenServer.call(server, {:upsert, merge}, 60_000)
  end

  @spec list(GenServer.server()) :: [RecentMerge.t()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @spec history(String.t(), GenServer.server()) :: {:ok, [RecentMerge.t()]} | {:error, :not_found}
  def history(id, server \\ __MODULE__) when is_binary(id), do: GenServer.call(server, {:history, id})

  @spec health(GenServer.server()) :: :writable | tuple()
  def health(server \\ __MODULE__), do: GenServer.call(server, :health)

  @spec reconciliation(GenServer.server()) :: map()
  def reconciliation(server \\ __MODULE__), do: GenServer.call(server, :reconciliation)

  @spec snapshot(GenServer.server()) :: %{merges: [RecentMerge.t()], health: term(), reconciliation: map()}
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @spec mark_reconciliation(boolean(), non_neg_integer(), GenServer.server()) :: :ok
  def mark_reconciliation(partial?, pages_fetched, server \\ __MODULE__)
      when is_boolean(partial?) and is_integer(pages_fetched) and pages_fetched >= 0 do
    GenServer.call(server, {:mark_reconciliation, partial?, pages_fetched})
  end

  @impl true
  def init(opts) do
    persistence = persistence_options(opts)

    case state_dir(opts) do
      {:ok, dir} -> {:ok, boot(dir, persistence)}
      {:error, reason} -> {:ok, unavailable_state(nil, persistence, {:path_unresolved, reason})}
    end
  end

  defp persistence_options(opts) do
    retention_limit = positive_limit(opts, :retention_limit, @retention_limit)

    %{
      append_fun: Keyword.get(opts, :append_fun, &DecisionLog.append/2),
      compact_fun: Keyword.get(opts, :compact_fun, &compact_log/2),
      sync_fun: Keyword.get(opts, :filesystem_sync_fun, &Fs.sync_filesystem/0),
      alert_fun: Keyword.get(opts, :alert_fun, &Alerts.emit_custom/3),
      retention_limit: retention_limit,
      compaction_record_limit:
        max(
          retention_limit,
          positive_limit(opts, :compaction_record_limit, @compaction_record_limit)
        )
    }
  end

  defp positive_limit(opts, key, default) do
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

  defp boot(dir, persistence) do
    path = Path.join(dir, @filename)

    case DecisionLog.prepare(dir, path, persistence.sync_fun) do
      :ok -> replay(path, persistence)
      {:error, reason} -> unavailable_state(path, persistence, {:directory_unavailable, reason})
    end
  end

  defp replay(path, persistence) do
    case DecisionLog.replay(path, &RecentMerge.decode_record/1) do
      {:ok, records, corruption} ->
        state =
          records
          |> Enum.reduce(base_state(path, persistence), &reduce_record/2)
          |> Map.put(:record_count, length(records))
          |> bound_projections()
          |> apply_corruption(corruption)

        compact_replayed_log(state)

      {:error, reason} ->
        unavailable_state(path, persistence, {:replay_failed, reason})
    end
  end

  defp base_state(path, persistence) do
    %{
      path: path,
      append_fun: persistence.append_fun,
      compact_fun: persistence.compact_fun,
      alert_fun: persistence.alert_fun,
      retention_limit: persistence.retention_limit,
      compaction_record_limit: persistence.compaction_record_limit,
      record_count: 0,
      current: %{},
      history: %{},
      writable?: true,
      health: :writable,
      reconciliation: %{status: :unknown, partial?: nil, pages_fetched: 0}
    }
  end

  defp reduce_record(merge, state) do
    %{
      state
      | current: Map.put(state.current, merge.id, merge),
        history: Map.update(state.history, merge.id, [merge], &(&1 ++ [merge]))
    }
  end

  defp bound_projections(state) do
    retained = state |> sorted_merges() |> Enum.take(state.retention_limit)
    retained_ids = Enum.map(retained, & &1.id)

    %{
      state
      | current: Map.new(retained, &{&1.id, &1}),
        history: Map.take(state.history, retained_ids)
    }
  end

  defp apply_corruption(state, nil), do: state

  defp apply_corruption(state, {:corrupt, line, reason}) do
    Logger.error("aiur_recent_merge_store phase=corruption path=#{state.path} line=#{line} reason=#{inspect(reason)}")

    emit_alert(
      state,
      "recent_merge_store.corrupted",
      "Recent repository merge audit is corrupt at #{state.path} line #{line} (#{inspect(reason)}); outcomes are read-only."
    )

    %{state | writable?: false, health: {:corrupt, line, reason}}
  end

  defp unavailable_state(path, persistence, reason) do
    Logger.error("aiur_recent_merge_store phase=unavailable reason=#{inspect(reason)}")

    state = %{
      path: path,
      append_fun: persistence.append_fun,
      compact_fun: persistence.compact_fun,
      alert_fun: persistence.alert_fun,
      retention_limit: persistence.retention_limit,
      compaction_record_limit: persistence.compaction_record_limit,
      record_count: 0,
      current: %{},
      history: %{},
      writable?: false,
      health: {:unavailable, reason},
      reconciliation: %{status: :unknown, partial?: nil, pages_fetched: 0}
    }

    emit_alert(
      state,
      "recent_merge_store.unavailable",
      "Recent repository merge audit is unavailable (#{inspect(reason)}); outcomes are read-only."
    )

    state
  end

  defp compact_replayed_log(%{writable?: false} = state), do: state

  defp compact_replayed_log(%{record_count: count, compaction_record_limit: limit} = state)
       when count > limit do
    case compact(state) do
      {:ok, compacted} ->
        compacted

      {:error, reason} ->
        health = {:compaction_failed, reason}
        Logger.error("aiur_recent_merge_store phase=boot_compaction_failed reason=#{inspect(reason)}")
        state = %{state | writable?: false, health: health}

        emit_alert(
          state,
          "recent_merge_store.unavailable",
          "Recent repository merge audit compaction failed (#{inspect(reason)}); outcomes are read-only."
        )

        state
    end
  end

  defp compact_replayed_log(state), do: state

  @impl true
  def handle_call({:upsert, _merge}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:upsert, merge}, _from, state) do
    case Map.get(state.current, merge.id) do
      nil -> persist(merge, state)
      existing -> evaluate_enrichment(existing, merge, state)
    end
  end

  def handle_call(:list, _from, state), do: {:reply, sorted_merges(state), state}

  def handle_call({:history, id}, _from, state) do
    case Map.fetch(state.history, id) do
      {:ok, records} -> {:reply, {:ok, records}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:health, _from, state), do: {:reply, state.health, state}
  def handle_call(:reconciliation, _from, state), do: {:reply, state.reconciliation, state}

  def handle_call(:snapshot, _from, state) do
    {:reply, %{merges: sorted_merges(state), health: state.health, reconciliation: state.reconciliation}, state}
  end

  def handle_call({:mark_reconciliation, partial?, pages_fetched}, _from, state) do
    reconciliation = reconciliation_status(state.reconciliation, partial?, pages_fetched)

    if reconciliation != state.reconciliation, do: notify()
    {:reply, :ok, %{state | reconciliation: reconciliation}}
  end

  defp reconciliation_status(%{partial?: true} = current, _partial?, pages_fetched) do
    %{current | status: :partial, pages_fetched: max(current.pages_fetched, pages_fetched)}
  end

  defp reconciliation_status(_current, partial?, pages_fetched) do
    %{
      status: if(partial?, do: :partial, else: :complete),
      partial?: partial?,
      pages_fetched: pages_fetched
    }
  end

  defp evaluate_enrichment(existing, incoming, state) do
    case RecentMerge.enrich(existing, incoming) do
      {:duplicate, merge} -> {:reply, {:ok, %{status: :duplicate, merge: merge}}, state}
      {:accepted, merge} -> persist(merge, state)
    end
  end

  defp persist(merge, state) do
    candidate =
      merge
      |> reduce_record(state)
      |> Map.update!(:record_count, &(&1 + 1))
      |> bound_projections()

    if candidate.record_count > candidate.compaction_record_limit do
      persist_compaction(merge, candidate, state)
    else
      persist_append(merge, candidate, state)
    end
  end

  defp persist_append(merge, candidate, state) do
    case state.append_fun.(state.path, RecentMerge.to_record(merge)) do
      :ok ->
        notify()
        {:reply, {:ok, %{status: :accepted, merge: merge}}, %{candidate | health: :writable}}

      {:error, reason} ->
        Logger.warning("aiur_recent_merge_store phase=append_failed reason=#{inspect(reason)}")
        health = {:append_failed, reason}
        if state.health != health, do: notify()
        {:reply, {:error, health}, %{state | health: health}}
    end
  end

  defp persist_compaction(merge, candidate, state) do
    case compact(candidate) do
      {:ok, compacted} ->
        notify()
        {:reply, {:ok, %{status: :accepted, merge: merge}}, compacted}

      {:error, reason} ->
        Logger.warning("aiur_recent_merge_store phase=compaction_failed reason=#{inspect(reason)}")
        health = {:compaction_failed, reason}
        if state.health != health, do: notify()
        {:reply, {:error, health}, %{state | health: health}}
    end
  end

  defp compact(state) do
    retained = state |> sorted_merges() |> Enum.reverse()
    compact_fun = state.compact_fun

    case compact_fun.(state.path, retained) do
      :ok ->
        {:ok,
         %{
           state
           | history: Map.new(retained, &{&1.id, [&1]}),
             record_count: length(retained),
             health: :writable
         }}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp compact_log(path, merges) do
    with :ok <- regular_log?(path) do
      contents = Enum.map(merges, &[Jason.encode!(RecentMerge.to_record(&1)), "\n"])
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

    _ =
      alert_fun.(topic, message,
        needs_attention: true,
        severity: "warning",
        reason: message
      )

    :ok
  rescue
    error -> Logger.warning("aiur_recent_merge_store phase=alert_failed error=#{Exception.message(error)}")
  catch
    kind, reason -> Logger.warning("aiur_recent_merge_store phase=alert_failed error=#{inspect({kind, reason})}")
  end

  defp sorted_merges(state) do
    state.current
    |> Map.values()
    |> Enum.sort_by(&{DateTime.to_unix(&1.merged_at, :microsecond), &1.number}, :desc)
  end

  defp notify do
    ObservabilityPubSub.broadcast_update()
  rescue
    error -> Logger.warning("aiur_recent_merge_store phase=notify_failed error=#{Exception.message(error)}")
  end
end

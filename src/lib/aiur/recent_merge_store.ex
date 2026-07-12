defmodule Aiur.RecentMergeStore do
  @moduledoc """
  Single-writer, append-only store for bounded recent repository merges.

  Every accepted snapshot is fsynced before the in-memory projection changes
  or the observability dashboard is notified. Replay serves the validated
  prefix but makes the store read-only on interior corruption.
  """

  use GenServer

  require Logger

  alias Aiur.{Alerts, Config, DecisionLog, RecentMerge}
  alias AiurWeb.ObservabilityPubSub

  @filename "recent_merges.ndjson"

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
    append_fun = Keyword.get(opts, :append_fun, &DecisionLog.append/2)
    sync_fun = Keyword.get(opts, :filesystem_sync_fun, &Aiur.Fs.sync_filesystem/0)

    case state_dir(opts) do
      {:ok, dir} -> {:ok, boot(dir, append_fun, sync_fun)}
      {:error, reason} -> {:ok, unavailable_state(nil, append_fun, {:path_unresolved, reason})}
    end
  end

  defp state_dir(opts) do
    case Keyword.get(opts, :state_dir) do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> Config.Paths.decision_state_dir()
    end
  end

  defp boot(dir, append_fun, sync_fun) do
    path = Path.join(dir, @filename)

    case DecisionLog.prepare(dir, path, sync_fun) do
      :ok -> replay(path, append_fun)
      {:error, reason} -> unavailable_state(path, append_fun, {:directory_unavailable, reason})
    end
  end

  defp replay(path, append_fun) do
    case DecisionLog.replay(path, &RecentMerge.decode_record/1) do
      {:ok, records, corruption} ->
        records
        |> Enum.reduce(base_state(path, append_fun), &reduce_record/2)
        |> apply_corruption(corruption)

      {:error, reason} ->
        unavailable_state(path, append_fun, {:replay_failed, reason})
    end
  end

  defp base_state(path, append_fun) do
    %{
      path: path,
      append_fun: append_fun,
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

  defp apply_corruption(state, nil), do: state

  defp apply_corruption(state, {:corrupt, line, reason}) do
    Logger.error("aiur_recent_merge_store phase=corruption path=#{state.path} line=#{line} reason=#{inspect(reason)}")

    _ =
      Alerts.emit_custom(
        "recent_merge_store.corrupted",
        "Recent repository merge audit is corrupt at #{state.path} line #{line} (#{inspect(reason)}); outcomes are read-only.",
        needs_attention: true
      )

    %{state | writable?: false, health: {:corrupt, line, reason}}
  end

  defp unavailable_state(path, append_fun, reason) do
    Logger.error("aiur_recent_merge_store phase=unavailable reason=#{inspect(reason)}")

    %{
      path: path,
      append_fun: append_fun,
      current: %{},
      history: %{},
      writable?: false,
      health: {:unavailable, reason},
      reconciliation: %{status: :unknown, partial?: nil, pages_fetched: 0}
    }
  end

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
    reconciliation = %{
      status: if(partial?, do: :partial, else: :complete),
      partial?: partial?,
      pages_fetched: pages_fetched
    }

    if reconciliation != state.reconciliation, do: notify()
    {:reply, :ok, %{state | reconciliation: reconciliation}}
  end

  defp evaluate_enrichment(existing, incoming, state) do
    case RecentMerge.enrich(existing, incoming) do
      {:duplicate, merge} -> {:reply, {:ok, %{status: :duplicate, merge: merge}}, state}
      {:accepted, merge} -> persist(merge, state)
    end
  end

  defp persist(merge, state) do
    case state.append_fun.(state.path, RecentMerge.to_record(merge)) do
      :ok ->
        new_state = reduce_record(merge, state)
        notify()
        {:reply, {:ok, %{status: :accepted, merge: merge}}, new_state}

      {:error, reason} ->
        Logger.warning("aiur_recent_merge_store phase=append_failed reason=#{inspect(reason)}")
        {:reply, {:error, {:append_failed, reason}}, state}
    end
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

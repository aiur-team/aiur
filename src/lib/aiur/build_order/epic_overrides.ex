defmodule Aiur.BuildOrder.EpicOverrides do
  @moduledoc "Durable local epic overrides. Unavailable reads never imply an empty registry."
  use GenServer
  alias Aiur.BuildOrder.EpicOverrides.{Batch, Journal}
  alias Aiur.BuildOrder.ProviderHealth
  alias Aiur.Config.Paths
  @topic "build-order-epic-overrides:changed"
  @max_bytes 8 * 1024 * 1024

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec set(String.t(), list(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def set(epic, ids, provenance, opts \\ []), do: write("set", epic, ids, provenance, opts)
  @spec clear(list(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def clear(ids, provenance, opts \\ []), do: write("clear", nil, ids, provenance, opts)

  defp write(op, epic, ids, provenance, opts) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:write, op, epic, ids, provenance, Keyword.get(opts, :now, &DateTime.utc_now/0)}
    )
  catch
    :exit, {:noproc, _} -> {:error, :epic_overrides_not_running}
    :exit, _reason -> {:error, :epic_overrides_outcome_unknown}
  end

  @spec catalog(keyword()) :: {:ok, [map()]} | {:error, atom()}
  def catalog(opts \\ []) do
    with {:ok, snapshot} <- snapshot(opts), do: Batch.catalog(snapshot.settings_fun)
  end

  @spec all(keyword()) :: {:ok, map(), ProviderHealth.t()} | {:error, ProviderHealth.t()}
  def all(opts \\ []), do: read(opts, & &1.overrides)

  @spec get_many(list(), keyword()) ::
          {:ok, map(), ProviderHealth.t()} | {:error, ProviderHealth.t()}
  def get_many(ids, opts \\ []), do: read(opts, &Map.take(&1.overrides, ids))
  @spec journal(list(), keyword()) :: {:ok, [map()]} | {:error, ProviderHealth.t()}
  def journal(ids, opts \\ []) do
    case read(opts, fn s -> Enum.filter(s.entries, &(entry_number(&1) in ids)) end) do
      {:ok, entries, _health} -> {:ok, entries}
      error -> error
    end
  end

  defp entry_number(entry), do: Map.get(entry, :number, entry["number"])
  @spec health(keyword()) :: ProviderHealth.t()
  def health(opts \\ []) do
    case snapshot(opts) do
      {:ok, state} -> state.health
      {:error, h} -> h
    end
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Aiur.PubSub, @topic)

  defp read(opts, select) do
    with {:ok, state} <- snapshot(opts) do
      if state.health.state == :healthy,
        do: {:ok, select.(state), state.health},
        else: {:error, state.health}
    end
  end

  defp snapshot(opts) do
    case :ets.lookup(mirror(Keyword.get(opts, :server, __MODULE__)), :snapshot) do
      [{:snapshot, state}] -> {:ok, state}
      [] -> {:error, unavailable(:epic_overrides_not_running)}
    end
  rescue
    ArgumentError -> {:error, unavailable(:epic_overrides_not_running)}
  end

  defp mirror(name), do: Module.concat(name, Mirror)
  defp unavailable(reason), do: %ProviderHealth{failure: reason}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    table =
      :ets.new(mirror(Keyword.get(opts, :name, __MODULE__)), [
        :named_table,
        :protected,
        read_concurrency: true
      ])

    state = %{
      synced?: false,
      sync: Keyword.get(opts, :sync, &Aiur.Fs.sync_filesystem/0),
      table: table,
      path: nil,
      repository: nil,
      entries: [],
      overrides: %{},
      generation: 0,
      health: unavailable(:epic_overrides_state_dir_unavailable),
      settings_fun: Keyword.get(opts, :settings_fun, &Aiur.Config.settings/0),
      writer: Keyword.get(opts, :writer, &Aiur.Fs.atomic_write/3),
      max_bytes: Keyword.get(opts, :max_bytes, @max_bytes)
    }

    loaded = initialize(state, opts)
    publish(loaded)
    {:ok, loaded}
  end

  defp initialize(state, opts) do
    with {:ok, repo} <- repository(opts),
         {:ok, dir} <- directory(opts),
         :ok <- mkdir(dir),
         path <- Path.join(dir, "epic-overrides.json"),
         {:ok, loaded} <- Journal.load(path, repo, state.max_bytes) do
      state
      |> Map.merge(loaded)
      |> Map.merge(%{
        repository: repo,
        path: path,
        health: healthy(loaded.generation),
        synced?: File.exists?(path)
      })
    else
      {:error, reason} -> %{state | health: unavailable(reason)}
    end
  rescue
    _ -> %{state | health: unavailable(:epic_overrides_state_dir_unavailable)}
  catch
    _, _ -> %{state | health: unavailable(:epic_overrides_state_dir_unavailable)}
  end

  defp repository(opts) do
    repo =
      if Keyword.has_key?(opts, :repository), do: opts[:repository], else: configured_repository()

    if is_binary(repo) and Regex.match?(~r/\A[^\/\s]+\/[^\/\s]+\z/, repo),
      do: {:ok, repo},
      else: {:error, :epic_overrides_unsupported_tracker}
  rescue
    _ -> {:error, :epic_overrides_unsupported_tracker}
  catch
    _, _ -> {:error, :epic_overrides_unsupported_tracker}
  end

  defp configured_repository do
    if Aiur.Tracker.adapter() == Aiur.GitHub.Tracker,
      do: Aiur.Tracker.project_identity(),
      else: nil
  end

  defp directory(opts) do
    case Keyword.fetch(opts, :state_dir) do
      {:ok, dir} when is_binary(dir) and dir != "" ->
        {:ok, dir}

      :error ->
        case Paths.epic_overrides_state_dir() do
          {:ok, _dir} = ok -> ok
          _ -> {:error, :epic_overrides_state_dir_unavailable}
        end

      _ ->
        {:error, :epic_overrides_state_dir_unavailable}
    end
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      _ -> {:error, :epic_overrides_state_dir_unavailable}
    end
  end

  defp healthy(generation),
    do: %ProviderHealth{
      generation: generation,
      state: :healthy,
      complete?: true,
      observed_at: DateTime.utc_now(),
      last_success_at: DateTime.utc_now()
    }

  defp publish(state),
    do:
      :ets.insert(
        state.table,
        {:snapshot, Map.take(state, [:overrides, :entries, :health, :settings_fun])}
      )

  @impl true
  def handle_call({:write, _op, _epic, _ids, _p, _now}, _from, %{health: %{state: state}} = s)
      when state != :healthy,
      do: {:reply, {:error, :epic_overrides_unavailable}, s}

  def handle_call({:write, op, epic, ids, p, now}, _from, state) do
    with true <- op == "clear" or is_binary(epic),
         {:ok, ids} <- Batch.validate(epic, ids, p, state.settings_fun),
         {:ok, at} <- now(now) do
      {next, results, changed} = Batch.apply(state, op, epic, ids, p, at)
      persist(state, next, results, changed)
    else
      false -> {:reply, {:error, :invalid_epic_arguments}, state}
      error -> {:reply, error, state}
    end
  end

  defp now(fun) when is_function(fun, 0), do: now(fun.())
  defp now(%DateTime{utc_offset: 0, std_offset: 0} = at), do: {:ok, at}
  defp now(_value), do: {:error, :invalid_epic_arguments}

  defp persist(state, _next, results, []),
    do: {:reply, {:ok, %{generation: state.generation, results: results}}, state}

  defp persist(state, next, results, changed) do
    case Journal.write(next) do
      :ok ->
        next = %{next | health: healthy(next.generation), synced?: true}
        publish(next)

        Phoenix.PubSub.broadcast(
          Aiur.PubSub,
          @topic,
          {:epic_overrides_changed, %{generation: next.generation, changed: changed, health: next.health}}
        )

        {:reply, {:ok, %{generation: next.generation, results: results}}, next}

      {:error, {:durability_unknown, _reason}} = error ->
        failed = %{state | health: unavailable(:epic_overrides_durability_unknown)}
        publish(failed)

        Phoenix.PubSub.broadcast(
          Aiur.PubSub,
          @topic,
          {:epic_overrides_changed, %{generation: state.generation, changed: [], health: failed.health}}
        )

        {:reply, error, failed}

      {:error, :epic_overrides_full} = error ->
        {:reply, error, state}

      {:error, reason} ->
        {:reply, {:error, {:write_failed, reason}}, state}
    end
  end
end

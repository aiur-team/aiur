defmodule Aiur.BuildOrder.Features.LabelProjection do
  @moduledoc "Durable feature-label projection from the registry and History, with no remote reads."
  use GenServer
  alias Aiur.BuildOrder.{Features, History}
  alias Aiur.BuildOrder.Features.{LabelRules, LabelStateStore, LabelWriter}
  alias Aiur.Config.Paths
  alias Aiur.GitHub.Config, as: GitHubConfig

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  @spec status(keyword()) :: map() | {:error, atom()}
  def status(opts \\ []), do: call(:status, opts)
  @spec label_states([pos_integer()], keyword()) :: {:ok, map()} | {:error, atom()}
  def label_states(numbers, opts \\ []), do: call({:label_states, numbers}, opts)
  @spec retry([{String.t(), pos_integer()}], keyword()) :: :ok | {:error, atom()}
  def retry(pairs, opts \\ []), do: call({:retry, pairs}, opts)
  @spec mark_labelled(String.t(), pos_integer(), map(), keyword()) :: :ok | {:error, term()}
  def mark_labelled(slug, number, times, opts \\ []), do: call({:mark_labelled, slug, number, times}, opts)

  defp call(message, opts) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), message, 60_000)
  catch
    :exit, _ -> {:error, :projection_not_running}
  end

  @impl true
  def init(opts) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    prefix = Keyword.get_lazy(opts, :label_prefix, &GitHubConfig.label_prefix/0)
    path = Keyword.get_lazy(opts, :state_path, &state_path/0)
    limit = Keyword.get_lazy(opts, :max_writes_per_minute, &write_limit/0)

    state = %{
      clock: clock,
      path: path,
      tracker: opts[:tracker],
      tracker_status: if(prefix == "feature", do: :prefix_collision, else: :ok),
      features: Keyword.get(opts, :features, Features),
      feature_opts: Keyword.get(opts, :feature_options, []),
      history: Keyword.get(opts, :history, History),
      history_opts: Keyword.get(opts, :history_options, []),
      entries: %{},
      snapshot: nil,
      rows: %{},
      health: nil,
      available?: false,
      loaded?: false,
      rebuild?: false,
      writes: :running,
      ensured: MapSet.new(),
      attempted: MapSet.new(),
      buckets: LabelWriter.buckets(clock.(), limit),
      conflicts: %{},
      unregistered: %{},
      rechecks: %{},
      tick_ms: Keyword.get(opts, :tick_ms, 60_000)
    }

    if prefix != "feature" do
      state.features.subscribe()
      state.history.subscribe()
      send(self(), :boot)
      Process.send_after(self(), :tick, state.tick_ms)
    end

    {:ok, state}
  end

  defp state_path do
    case Paths.build_features_state_dir() do
      {:ok, dir} -> Path.join(dir, "label-projection.json")
      {:error, _} -> nil
    end
  end

  defp write_limit do
    case Aiur.Config.settings() do
      {:ok, settings} -> settings.build_queue.max_writes_per_minute
      _ -> 20
    end
  end

  @impl true
  def handle_call(message, _from, state) do
    state = registry(state)
    {result, state} = request(message, state)
    {:reply, result, state}
  end

  defp request(:status, %{tracker_status: :prefix_collision, snapshot: snapshot} = state) when not is_nil(snapshot) do
    entries = LabelRules.reconcile_registry(%{}, snapshot.owners, state.clock.())
    {status_value(%{state | entries: entries}), state}
  end

  defp request(:status, state) do
    result = with :ok <- available(state), do: status_value(state)
    {result, state}
  end

  defp request({:label_states, numbers}, state) do
    result =
      with :ok <- available(state) do
        states = for n <- numbers, owner = state.snapshot.owners[n], owner != nil, entry = state.entries[{owner.feature, n}], entry != nil, into: %{}, do: {n, entry.state}
        {:ok, states}
      end

    {result, state}
  end

  defp request({:retry, pairs}, state) do
    case available(state) do
      :ok ->
        entries = Enum.reduce(pairs, state.entries, &retry_entry(&1, &2, state))
        next = LabelWriter.persist(%{state | entries: entries, attempted: MapSet.difference(state.attempted, MapSet.new(pairs))})
        {available(next), next}

      error ->
        {error, state}
    end
  end

  defp request({:mark_labelled, slug, n, times}, state) do
    with :ok <- available(state),
         %{feature: ^slug} <- state.snapshot.owners[n],
         %{state: :held_backfill} = entry <- state.entries[{slug, n}],
         %{seen_at: %DateTime{}, written_at: written} <- times,
         true <- is_nil(written) or is_struct(written, DateTime) do
      entry = %{entry | state: :labelled, seen_at: times.seen_at, written_at: written}
      next = LabelWriter.persist(%{state | entries: Map.put(state.entries, {slug, n}, entry)})
      {available(next), next}
    else
      {:error, _} = error -> {error, state}
      %{state: _} -> {{:error, :not_held}, state}
      %{feature: _} -> {{:error, {:not_member, [n]}}, state}
      nil -> {{:error, if(match?(%{feature: ^slug}, state.snapshot && state.snapshot.owners[n]), do: :not_held, else: {:not_member, [n]})}, state}
      _ -> {{:error, :invalid_times}, state}
    end
  end

  defp retry_entry(key, entries, state) do
    case entries[key] do
      %{state: :failed} = entry -> Map.put(entries, key, reset(entry, key, state))
      _ -> entries
    end
  end

  defp available(%{snapshot: nil}), do: {:error, :registry_unavailable}
  defp available(%{available?: false}), do: {:error, :projection_state_unavailable}
  defp available(_), do: :ok

  defp status_value(state) do
    entries = state.entries

    %{
      tracker: state.tracker_status,
      writes: state.writes,
      observation: observation(state.health),
      observed_at: if(state.health, do: state.health.observed_at || :unknown, else: :unknown),
      pending: Enum.count(entries, fn {_, entry} -> entry.state in [:pending_label, :pending_unlabel] end),
      failed: for({{slug, n}, %{state: :failed, last_error: error}} <- entries, do: {slug, n, error}),
      conflicts: Enum.sort(state.conflicts),
      unregistered: state.unregistered |> Map.values() |> List.flatten() |> Enum.sort()
    }
  end

  defp observation(nil), do: :not_running
  defp observation(%{failure: :history_not_running}), do: :not_running
  defp observation(health), do: health.state

  @impl true
  def handle_info(:boot, state), do: {:noreply, pass(state, :all)}

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, pass(%{state | writes: :running, attempted: MapSet.new()}, :all)}
  end

  def handle_info({:build_order_features_changed, %{changed: numbers}}, state), do: {:noreply, pass(state, {:registry, numbers})}
  def handle_info({:build_order_history_changed, %{changed: numbers}}, state), do: {:noreply, pass(state, numbers)}
  def handle_info({:recheck, n}, state), do: {:noreply, pass(%{state | rechecks: Map.delete(state.rechecks, n)}, [n])}

  defp registry(state) do
    case state.features.snapshot(state.feature_opts) do
      {:ok, snapshot} -> %{state | snapshot: snapshot}
      {:error, _} -> %{state | snapshot: nil}
    end
  end

  defp pass(%{tracker_status: :prefix_collision} = state, _), do: state

  defp pass(state, selection) do
    state = registry(state) |> observations(selection) |> load()

    if state.snapshot && state.loaded? do
      entries = LabelRules.reconcile_registry(state.entries, state.snapshot.owners, state.clock.())
      state = save_changes(state, entries)
      state = if state.available? and match?(%{state: :healthy}, state.health), do: decide_rows(state, selection), else: state
      if state.snapshot, do: LabelWriter.run(state), else: state
    else
      state
    end
  end

  defp observations(state, {:registry, _numbers}), do: state

  defp observations(state, :all) do
    case state.history.snapshot(state.history_opts) do
      {:ok, %{rows: rows, health: health}} -> %{state | rows: rows, health: health}
      {:error, health} -> %{state | health: health}
    end
  end

  defp observations(state, numbers) do
    case state.history.rows(numbers, state.history_opts) do
      {:ok, rows, health} -> %{state | rows: Enum.reduce(rows, state.rows, &Map.put(&2, &1.number, &1)), health: health}
      {:error, health} -> %{state | health: health}
    end
  end

  defp load(%{loaded?: true} = state), do: state
  defp load(%{snapshot: nil} = state), do: state

  defp load(state) do
    result = if state.rebuild?, do: :rebuild, else: LabelStateStore.load(state.path)

    case result do
      {:ok, entries} ->
        state = %{state | entries: entries, loaded?: true, available?: true}
        entries = Map.new(entries, fn {key, entry} -> {key, if(entry.state == :failed, do: reset(entry, key, state), else: entry)} end)
        save_changes(state, entries)

      :rebuild ->
        rebuild(%{state | rebuild?: true})

      {:error, _} ->
        state
    end
  end

  defp rebuild(%{health: %{state: :healthy}} = state) do
    case LabelStateStore.rebuild(state.snapshot, state.rows, state.features, state.feature_opts, state.clock.()) do
      {:ok, entries} -> LabelWriter.persist(%{state | entries: entries, loaded?: true, rebuild?: false})
      {:error, _} -> state
    end
  end

  defp rebuild(state), do: state

  defp reset(entry, {slug, n}, state) do
    owned? = match?(%{feature: ^slug}, state.snapshot.owners[n])
    %{entry | state: if(owned?, do: :pending_label, else: :pending_unlabel), attempts: 0, last_error: nil, queued_at: state.clock.()}
  end

  defp decide_rows(state, selection) do
    rows =
      case selection do
        :all -> state.rows
        {:registry, numbers} -> Map.take(state.rows, numbers)
        numbers -> Map.take(state.rows, numbers)
      end

    by_number = Enum.group_by(state.entries, fn {{_slug, n}, _} -> n end)

    Enum.reduce(Enum.sort(rows), state, fn {n, row}, acc ->
      acc = %{acc | conflicts: Map.delete(acc.conflicts, n), unregistered: Map.delete(acc.unregistered, n)}

      if acc.snapshot do
        row = Map.merge(row, %{registered_slugs: MapSet.new(Map.keys(acc.snapshot.features)), health: acc.health})
        actions = LabelRules.decide(row, acc.snapshot.owners[n], Map.new(Map.get(by_number, n, [])), acc.clock.())
        Enum.reduce(actions, acc, &action/2)
      else
        acc
      end
    end)
  end

  defp action({:put, key, entry}, state) do
    changed? = Map.delete(state.entries[key], :seen_at) != Map.delete(entry, :seen_at)
    next = %{state | entries: Map.put(state.entries, key, entry)}
    if changed?, do: LabelWriter.persist(next), else: next
  end

  defp action({:conflict, n, slugs}, state), do: %{state | conflicts: Map.put(state.conflicts, n, slugs)}
  defp action({:unregistered, n, slug}, state), do: %{state | unregistered: Map.update(state.unregistered, n, [{n, slug}], &[{n, slug} | &1])}

  defp action({:recheck, at, n}, state) do
    unless Map.has_key?(state.rechecks, n), do: Process.send_after(self(), {:recheck, n}, max(DateTime.diff(at, state.clock.(), :millisecond) + 1, 1))
    %{state | rechecks: Map.put(state.rechecks, n, at)}
  end

  defp action({operation, slug, [n] = numbers, meta}, state) when operation in [:add, :remove] do
    case apply(state.features, operation, [slug, numbers, meta ++ state.feature_opts]) do
      {:ok, _} ->
        registry_action(operation, slug, n, registry(state))

      {:error, {:owned_elsewhere, pairs}} ->
        %{state | conflicts: Map.put(state.conflicts, n, Enum.sort(Enum.uniq([slug | Enum.map(pairs, &elem(&1, 1))])))}

      {:error, _} ->
        registry(state)
    end
  end

  defp registry_action(_operation, _slug, _n, %{snapshot: nil} = state), do: state

  defp registry_action(operation, slug, n, state) do
    entries = LabelRules.reconcile_registry(state.entries, state.snapshot.owners, state.clock.())

    entry =
      if operation == :remove,
        do: %{LabelRules.entry(:unlabelled, state.clock.()) | written_at: state.clock.()},
        else: %{entries[{slug, n}] | seen_at: state.rows[n].observed_at}

    save_changes(state, Map.put(entries, {slug, n}, entry))
  end

  defp save_changes(state, entries) do
    changed? = Map.new(state.entries, fn {key, entry} -> {key, Map.delete(entry, :seen_at)} end) != Map.new(entries, fn {key, entry} -> {key, Map.delete(entry, :seen_at)} end)
    state = %{state | entries: entries}
    if changed? or not state.available?, do: LabelWriter.persist(state), else: state
  end
end

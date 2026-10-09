defmodule Aiur.BuildProgress do
  @moduledoc """
  Current queue and Build Order progress facts, with durable milestone latches.

  Producers own counts and percent; Build Order generations are assigned durably.
  Reads return facts for `:all` or one scope. Facts are volatile; milestone
  latches and Build Order generation markers survive restart. Corrupt or unavailable
  storage disables milestones until restart,
  while reads and change signals continue. Persisting before publication favors
  a missed notification over a repeated one if the daemon crashes between them.
  Generation tracking and milestone writes share this owner to serialize persistence.
  """
  use GenServer

  require Logger

  alias Aiur.{Alerts, BuildOrder.ProgressGeneration, Config.Paths, JsonStore}

  @topic "build_progress"
  @changed_fields [:percent, :resolution, :freshness, :generation]
  @type scope :: {:queue, String.t()} | {:build_order, String.t() | pos_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec put_fact(map(), GenServer.server()) :: :ok | {:error, :invalid_fact}
  def put_fact(fact, server \\ __MODULE__) do
    GenServer.call(server, {:put_fact, fact})
  end

  @spec put_build_order_fact(map(), GenServer.server()) :: :ok | {:error, :invalid_fact}
  def put_build_order_fact(fact, server \\ __MODULE__), do: GenServer.call(server, {:put_build_order_fact, fact})

  @spec facts(:all | scope(), GenServer.server()) :: [map()]
  def facts(filter \\ :all, server \\ __MODULE__) do
    GenServer.call(server, {:facts, filter})
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Aiur.PubSub, @topic)

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :state_file, &state_file/0)
    {:ok, %{facts: %{}, latches: load_latches(path), path: path}}
  end

  @impl true
  def handle_call({:facts, :all}, _from, state), do: {:reply, Map.values(state.facts), state}
  def handle_call({:facts, scope}, _from, state), do: {:reply, state.facts |> Map.take([scope]) |> Map.values(), state}

  def handle_call({:put_build_order_fact, %{scope: {:build_order, _}} = fact}, from, state) do
    if valid_fact?(Map.put(fact, :generation, 1)) do
      fact = ProgressGeneration.assign(fact, state.latches, Map.get(state.facts, fact.scope))
      handle_call({:put_fact, fact}, from, state)
    else
      {:reply, {:error, :invalid_fact}, state}
    end
  end

  def handle_call({:put_build_order_fact, _fact}, _from, state), do: {:reply, {:error, :invalid_fact}, state}

  def handle_call({:put_fact, fact}, _from, state) do
    if valid_fact?(fact) do
      previous = Map.get(state.facts, fact.scope)
      state = %{state | facts: Map.put(state.facts, fact.scope, fact)}

      if is_nil(previous) or Map.take(previous, @changed_fields) != Map.take(fact, @changed_fields) do
        Phoenix.PubSub.broadcast(Aiur.PubSub, @topic, {:build_progress_changed, fact})
      end

      {:reply, :ok, announce(fact, remember_generation(fact, state))}
    else
      {:reply, {:error, :invalid_fact}, state}
    end
  end

  defp remember_generation(%{scope: {:build_order, id}, generation: generation}, %{latches: latches} = state) when is_map(latches) do
    key = Jason.encode!([:build_order, id, generation])

    if Map.has_key?(latches, key) do
      state
    else
      latches = Map.put(latches, key, 0)

      case persist(state.path, latches) do
        :ok ->
          %{state | latches: latches}

        {:error, reason} ->
          disable_milestones(reason, state)
      end
    end
  end

  defp remember_generation(_fact, state), do: state

  defp valid_fact?(%{
         scope: {kind, id},
         generation: generation,
         completed: completed,
         resolved: resolved,
         total: total,
         percent: percent,
         resolution: resolution,
         freshness: freshness,
         observed_at: observed_at
       }) do
    kind in [:queue, :build_order] and valid_identity?(id) and valid_identity?(generation) and
      valid_counts?(completed, resolved, total) and
      valid_percent?(percent) and
      resolution in [:resolved, :partial, :unresolved, :unknown] and freshness in [:current, :stale, :unknown] and
      match?(%DateTime{}, observed_at)
  end

  defp valid_fact?(_fact), do: false
  defp valid_identity?(value), do: (is_binary(value) and value != "") or (is_integer(value) and value > 0)
  defp valid_percent?(nil), do: true
  defp valid_percent?(percent), do: is_number(percent) and percent >= 0 and percent <= 100

  defp valid_counts?(completed, resolved, total) do
    Enum.all?([completed, resolved, total], &(is_nil(&1) or (is_integer(&1) and &1 >= 0))) and
      (is_nil(completed) or is_nil(resolved) or completed <= resolved) and
      (is_nil(resolved) or is_nil(total) or resolved <= total)
  end

  defp announce(%{resolution: resolution, freshness: :current, percent: percent} = fact, %{latches: latches} = state)
       when resolution in [:resolved, :partial] and is_number(percent) and is_map(latches) do
    {kind, id} = fact.scope
    key = Jason.encode!([kind, id, fact.generation])
    milestone = Enum.find([100, 75, 50, 25], 0, &(percent >= &1))

    if milestone > Map.get(latches, key, 0) do
      persist_and_emit(fact, milestone, key, state)
    else
      state
    end
  end

  defp announce(_fact, state), do: state

  defp persist_and_emit(fact, milestone, key, state) do
    latches = Map.put(state.latches, key, milestone)

    case persist(state.path, latches) do
      :ok ->
        {kind, id} = fact.scope

        result =
          Alerts.emit_system("system.#{kind}.#{id}.progress",
            message: "#{kind} #{id} reached #{milestone}% progress",
            severity: "info",
            needs_attention: false,
            exchange_payload: %{milestone: milestone, percent: fact.percent, generation: fact.generation}
          )

        if result != :ok, do: Logger.error("BuildProgress milestone publication failed: #{inspect(result)}")
        %{state | latches: latches}

      {:error, reason} ->
        disable_milestones(reason, state)
    end
  end

  defp disable_milestones(reason, state) do
    unavailable(reason)
    %{state | latches: nil}
  end

  defp persist(path, latches) do
    JsonStore.write!(path, latches)
  rescue
    error -> {:error, error}
  end

  defp state_file do
    case Paths.decision_state_dir() do
      {:ok, dir} -> Path.join(dir, "build-progress.json")
      {:error, reason} -> unavailable(reason)
    end
  end

  defp load_latches(nil), do: nil

  defp load_latches(path) do
    case JsonStore.read(path, %{}) do
      {:ok, latches} when is_map(latches) ->
        if Enum.all?(latches, &valid_latch?/1), do: latches, else: unavailable(:invalid_latches)

      other ->
        unavailable(other)
    end
  end

  defp valid_latch?({key, milestone}) do
    case Jason.decode(key) do
      {:ok, [kind, id, generation]} ->
        kind in ["queue", "build_order"] and valid_identity?(id) and valid_identity?(generation) and (milestone in [25, 50, 75, 100] or (kind == "build_order" and milestone == 0))

      _ ->
        false
    end
  end

  defp unavailable(reason) do
    Logger.error("BuildProgress milestones disabled: #{inspect(reason)}")
    nil
  end
end

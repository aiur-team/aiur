defmodule Aiur.BuildOrder.Features do
  @moduledoc "Durable, single-writer feature and epic registry and membership journal."
  use GenServer

  alias Aiur.BuildOrder.Epics.Journal, as: EpicJournal
  alias Aiur.BuildOrder.Epics.Operations, as: EpicOperations
  alias Aiur.BuildOrder.Features.{Journal, Operations, Persistence, Reads, RootImportMapping}
  alias Aiur.BuildOrder.ProviderHealth

  @topic "build-order-features:changed"
  @epic_topic "build-order-epics:changed"
  @type result :: {:ok, map()} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, Aiur.Project.carry(opts), name: Keyword.get(opts, :name, Aiur.Project.via(__MODULE__)))
  end

  @spec create(String.t(), map(), keyword()) :: result()
  def create(slug, attrs, meta), do: write(:create, slug, attrs, meta)
  @spec update_feature(String.t(), map(), keyword()) :: result()
  def update_feature(slug, attrs, meta), do: write(:update_feature, slug, attrs, meta)
  @spec add_epic(String.t(), map(), keyword()) :: result()
  def add_epic(slug, epic, meta), do: write(:add_epic, slug, epic, meta)
  @spec add(String.t(), [pos_integer()], keyword()) :: result()
  def add(slug, numbers, meta), do: write(:add, slug, numbers, meta)
  @spec confirm(String.t(), [pos_integer()], keyword()) :: result()
  def confirm(slug, numbers, meta), do: write(:confirm, slug, numbers, meta)
  @spec remove(String.t(), [pos_integer()], keyword()) :: result()
  def remove(slug, numbers, meta), do: write(:remove, slug, numbers, meta)
  @spec also(String.t(), [pos_integer()], keyword()) :: result()
  def also(slug, numbers, meta), do: write(:also, slug, numbers, meta)
  @spec set_baseline(String.t(), keyword()) :: result()
  def set_baseline(slug, meta), do: write(:set_baseline, slug, nil, meta)

  @doc "Creates an epic record, or confirms the same one already exists."
  @spec epic_create(String.t(), map(), keyword()) :: result()
  def epic_create(slug, attrs, meta), do: epic_write(:create, slug, attrs, meta)
  @doc "Changes an epic's label, icon or hue."
  @spec epic_edit(String.t(), map(), keyword()) :: result()
  def epic_edit(slug, attrs, meta), do: epic_write(:edit, slug, attrs, meta)
  @doc "Adds feature slugs to an epic's ordered feature list."
  @spec epic_add(String.t(), [String.t()], keyword()) :: result()
  def epic_add(slug, features, meta), do: epic_write(:add, slug, features, meta)
  @doc "Removes feature slugs from an epic's ordered feature list."
  @spec epic_remove(String.t(), [String.t()], keyword()) :: result()
  def epic_remove(slug, features, meta), do: epic_write(:remove, slug, features, meta)

  @spec snapshot(keyword()) :: result()
  def snapshot(opts \\ []), do: read(:snapshot, opts)
  @spec epics(keyword()) :: result()
  def epics(opts \\ []), do: read(:epics, opts)
  @spec epic(String.t(), keyword()) :: result()
  def epic(slug, opts \\ []), do: read({:epic, slug}, opts)
  @spec owner(pos_integer(), keyword()) :: result() | :none
  def owner(number, opts \\ []), do: read({:owner, number}, opts)
  @doc "The ticket's owning feature and that feature's epic (nil when none); `:unknown` when it has no owner or the registry cannot answer."
  @spec feature_and_epic(pos_integer(), keyword()) :: {:ok, %{feature: String.t(), epic: String.t() | nil}} | :unknown
  def feature_and_epic(number, opts \\ []) do
    case owner(number, opts) do
      {:ok, %{feature: feature}} when is_binary(feature) -> {:ok, %{feature: feature, epic: epic_of(feature, opts)}}
      _none -> :unknown
    end
  end

  defp epic_of(feature, opts) do
    with {:ok, %{epics: epics}} <- epics(opts),
         %{slug: slug} <- Enum.find(epics, &(feature in Map.get(&1, :features, []))) do
      slug
    else
      _none -> nil
    end
  end

  @spec memberships(keyword()) :: {:ok, [map()]} | {:error, ProviderHealth.t()}
  def memberships(opts \\ []), do: read(:memberships, opts)
  @spec journal(String.t(), keyword()) :: {:ok, [map()]} | {:error, ProviderHealth.t()}
  def journal(slug, opts \\ []), do: read({:journal, slug}, opts)
  @spec health(keyword()) :: ProviderHealth.t()
  def health(opts \\ []), do: call(:health, opts, :health)
  @spec subscribe() :: :ok
  def subscribe, do: Phoenix.PubSub.subscribe(Aiur.PubSub, @topic)
  @doc "Subscribes to epic record changes; features keep their own topic."
  @spec subscribe_epics() :: :ok
  def subscribe_epics, do: Phoenix.PubSub.subscribe(Aiur.PubSub, @epic_topic)

  @doc "The slug of the feature a Build Order root is imported as."
  @spec root_slug(pos_integer()) :: String.t()
  defdelegate root_slug(number), to: RootImportMapping, as: :slug

  @impl true
  def init(opts) do
    Aiur.Project.adopt(opts)
    {:ok, Persistence.boot(opts)}
  end

  @impl true
  def handle_call(:health, _from, state), do: {:reply, state.health, state}
  def handle_call({:read, query}, _from, state), do: {:reply, Reads.read(query, state), state}

  def handle_call({:write, _, _, _, _}, _from, %{writable?: false} = state) do
    {:reply, {:error, state.health.failure}, state}
  end

  def handle_call({:write, op, slug, input, meta}, _from, state) do
    context = %{now: state.clock.(), general_epics: state.general_epics}

    case Operations.events(op, slug, input, meta, state.projection, context) do
      {:ok, events, kept} -> events |> apply_events(meta, context.now, state) |> with_kept(kept)
      {:ok, events} -> events |> apply_events(meta, context.now, state) |> confirmation_result(op, input, state.projection.owners)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:epic_write, _, _, _, _}, _from, %{epic_writable?: false} = state) do
    {:reply, {:error, epic_failure(state)}, state}
  end

  def handle_call({:epic_write, op, slug, input, meta}, _from, state) do
    context = %{now: state.clock.(), features: state.projection, lanes: lanes(state)}

    case EpicOperations.events(op, slug, input, meta, state.epic_projection, context) do
      {:ok, []} -> {:reply, {:ok, epic_result([], state)}, state}
      {:ok, events} -> persist_epic(events, meta, context.now, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp confirmation_result({:reply, {:ok, result}, state}, :confirm, ids, owners) do
    rows =
      Enum.map(Enum.uniq(ids), fn id ->
        previous = owners[id]
        %{id: id, outcome: if(id in result.changed, do: :confirmed, else: :unchanged), epic: previous.epic, previous: previous}
      end)

    {:reply, {:ok, Map.put(result, :results, rows)}, state}
  end

  defp confirmation_result(reply, _op, _ids, _owners), do: reply

  defp apply_events([], _meta, _now, state), do: {:reply, {:ok, Reads.changed([], state)}, state}
  defp apply_events(events, meta, now, state), do: persist(events, meta, now, state)

  defp with_kept({:reply, {:ok, result}, state}, kept), do: {:reply, {:ok, Map.put(result, :kept, kept)}, state}
  defp with_kept(reply, _kept), do: reply

  defp persist(events, meta, now, state) do
    record = %{v: 1, seq: state.projection.seq + 1, recorded_at: now, source: meta[:source], actor: meta[:actor], events: events}

    with {:ok, validated} <- Journal.validate(Journal.encode(record)),
         {:ok, projection} <- Journal.fold(state.projection, validated) do
      append(record, projection, state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp append(record, projection, state) do
    case Persistence.append(record, projection, state) do
      {:ok, next} ->
        result = Reads.changed(record.events, next)
        broadcast(@topic, {:build_order_features_changed, result})
        {:reply, {:ok, result}, next}

      {:error, reason, next} ->
        {:reply, {:error, reason}, next}
    end
  end

  defp persist_epic(events, meta, now, state) do
    record = %{v: 1, seq: state.epic_projection.seq + 1, recorded_at: now, source: meta[:source], actor: meta[:actor], events: events}

    with {:ok, validated} <- EpicJournal.validate(EpicJournal.encode(record)),
         {:ok, projection} <- EpicJournal.fold(state.epic_projection, validated) do
      append_epic(record, projection, state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp append_epic(record, projection, state) do
    case Persistence.append_epic(record, projection, state) do
      {:ok, next} ->
        result = epic_result(record.events, next)
        broadcast(@epic_topic, {:build_order_epics_changed, result})
        {:reply, {:ok, result}, next}

      {:error, reason, next} ->
        {:reply, {:error, reason}, next}
    end
  end

  defp epic_result(events, state) do
    %{changed: Enum.map(events, & &1.type), epic: epic_slug(events), generation: generation(state.epic_health)}
  end

  defp epic_slug([%{epic: %{slug: slug}} | _]), do: slug
  defp epic_slug([%{epic: slug} | _]), do: slug
  defp epic_slug(_events), do: nil

  defp generation(%ProviderHealth{generation: generation}), do: generation
  defp generation(_health), do: :unknown

  defp epic_failure(state), do: (state.epic_health && state.epic_health.failure) || :epics_unavailable

  defp lanes(state) do
    case state.general_epics.() do
      {:ok, lanes} when is_list(lanes) -> lanes
      _ -> []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp broadcast(topic, message) do
    if Process.whereis(Aiur.PubSub), do: Phoenix.PubSub.broadcast(Aiur.PubSub, topic, message)
  end

  defp write(op, slug, input, meta) when is_list(meta) do
    if Keyword.keyword?(meta), do: call({:write, op, slug, input, meta}, meta, :write), else: {:error, :invalid_meta}
  end

  defp write(_, _, _, _), do: {:error, :invalid_meta}

  defp epic_write(op, slug, input, meta) when is_list(meta) do
    if Keyword.keyword?(meta), do: call({:epic_write, op, slug, input, meta}, meta, :write), else: {:error, :invalid_meta}
  end

  defp epic_write(_, _, _, _), do: {:error, :invalid_meta}
  defp read(query, opts), do: call({:read, query}, opts, :read)

  # ponytail: mailbox reads suffice; add ETS only after measured read latency exceeds 5 ms.
  defp call(message, opts, kind) do
    GenServer.call(Keyword.get(opts, :server, Aiur.Project.via(__MODULE__)), message, Keyword.get(opts, :timeout, 60_000))
  catch
    :exit, {:noproc, _} -> missing(kind)
    :exit, {:normal, _} -> missing(kind)
    :exit, {:shutdown, _} -> missing(kind)
  end

  defp missing(:write), do: {:error, :features_not_running}
  defp missing(:health), do: ProviderHealth.new(:unknown, :unavailable, false, failure: :features_not_running)
  defp missing(:read), do: {:error, missing(:health)}
end

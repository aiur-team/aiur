defmodule Aiur.BuildOrder.Features do
  @moduledoc "Durable, single-writer feature registry and membership journal."
  use GenServer

  alias Aiur.BuildOrder.Features.{Journal, Operations, Persistence, Reads}
  alias Aiur.BuildOrder.ProviderHealth

  @topic "build-order-features:changed"
  @type result :: {:ok, map()} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec create(String.t(), map(), keyword()) :: result()
  def create(slug, attrs, meta), do: write(:create, slug, attrs, meta)
  @spec update_feature(String.t(), map(), keyword()) :: result()
  def update_feature(slug, attrs, meta), do: write(:update_feature, slug, attrs, meta)
  @spec add_epic(String.t(), map(), keyword()) :: result()
  def add_epic(slug, epic, meta), do: write(:add_epic, slug, epic, meta)
  @spec add(String.t(), [pos_integer()], keyword()) :: result()
  def add(slug, numbers, meta), do: write(:add, slug, numbers, meta)
  @spec remove(String.t(), [pos_integer()], keyword()) :: result()
  def remove(slug, numbers, meta), do: write(:remove, slug, numbers, meta)
  @spec also(String.t(), [pos_integer()], keyword()) :: result()
  def also(slug, numbers, meta), do: write(:also, slug, numbers, meta)
  @spec set_baseline(String.t(), keyword()) :: result()
  def set_baseline(slug, meta), do: write(:set_baseline, slug, nil, meta)

  @spec snapshot(keyword()) :: result()
  def snapshot(opts \\ []), do: read(:snapshot, opts)
  @spec owner(pos_integer(), keyword()) :: result() | :none
  def owner(number, opts \\ []), do: read({:owner, number}, opts)
  @spec memberships(keyword()) :: {:ok, [map()]} | {:error, ProviderHealth.t()}
  def memberships(opts \\ []), do: read(:memberships, opts)
  @spec journal(String.t(), keyword()) :: {:ok, [map()]} | {:error, ProviderHealth.t()}
  def journal(slug, opts \\ []), do: read({:journal, slug}, opts)
  @spec health(keyword()) :: ProviderHealth.t()
  def health(opts \\ []), do: call(:health, opts, :health)
  @spec subscribe() :: :ok
  def subscribe, do: Phoenix.PubSub.subscribe(Aiur.PubSub, @topic)

  @impl true
  def init(opts), do: {:ok, Persistence.boot(opts)}

  @impl true
  def handle_call(:health, _from, state), do: {:reply, state.health, state}
  def handle_call({:read, query}, _from, state), do: {:reply, Reads.read(query, state), state}

  def handle_call({:write, _, _, _, _}, _from, %{writable?: false} = state) do
    {:reply, {:error, state.health.failure}, state}
  end

  def handle_call({:write, op, slug, input, meta}, _from, state) do
    context = %{now: state.clock.(), general_epics: state.general_epics}

    case Operations.events(op, slug, input, meta, state.projection, context) do
      {:ok, []} -> {:reply, {:ok, Reads.changed([], state)}, state}
      {:ok, events} -> persist(events, meta, context.now, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

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
        broadcast(result)
        {:reply, {:ok, result}, next}

      {:error, reason, next} ->
        {:reply, {:error, reason}, next}
    end
  end

  defp broadcast(result) do
    if Process.whereis(Aiur.PubSub), do: Phoenix.PubSub.broadcast(Aiur.PubSub, @topic, {:build_order_features_changed, result})
  end

  defp write(op, slug, input, meta) when is_list(meta) do
    if Keyword.keyword?(meta), do: call({:write, op, slug, input, meta}, meta, :write), else: {:error, :invalid_meta}
  end

  defp write(_, _, _, _), do: {:error, :invalid_meta}
  defp read(query, opts), do: call({:read, query}, opts, :read)

  # ponytail: mailbox reads suffice; add ETS only after measured read latency exceeds 5 ms.
  defp call(message, opts, kind) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), message, 60_000)
  catch
    :exit, {:noproc, _} -> missing(kind)
    :exit, {:normal, _} -> missing(kind)
    :exit, {:shutdown, _} -> missing(kind)
  end

  defp missing(:write), do: {:error, :features_not_running}
  defp missing(:health), do: ProviderHealth.new(:unknown, :unavailable, false, failure: :features_not_running)
  defp missing(:read), do: {:error, missing(:health)}
end

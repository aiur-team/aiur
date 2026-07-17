defmodule Aiur.CurrentRunMembership.Store do
  @moduledoc """
  Daemon-private durable store for the current-run membership projection.

  The GenServer owns live snapshot APIs while focused recovery, codec, and
  persistence modules preserve the content-free journal/checkpoint boundary.
  """

  use GenServer

  alias Aiur.Boot
  alias Aiur.CurrentRunMembership.{Event, Projection}
  alias Aiur.CurrentRunMembership.Store.{Recovery, Runtime}
  alias Aiur.TrackerIdentity

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec observe(TrackerIdentity.t(), Event.lifecycle(), keyword()) :: {:ok, map()} | {:error, term()}
  def observe(identity, lifecycle, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
    source = Keyword.get(opts, :source, :status_report)
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(server, {:observe, identity, lifecycle, observed_at, source}, timeout)
  end

  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:snapshot, Keyword.get(opts, :limit, 1_000)})
  end

  @spec lookup(TrackerIdentity.t(), GenServer.server()) :: {:ok, Projection.member()} | {:error, :not_found}
  def lookup(identity, server \\ __MODULE__), do: GenServer.call(server, {:lookup, identity})

  @spec generation(GenServer.server()) :: non_neg_integer()
  def generation(server \\ __MODULE__), do: GenServer.call(server, :generation)

  @spec health(GenServer.server()) :: term()
  def health(server \\ __MODULE__), do: GenServer.call(server, :health)

  @spec freshness(GenServer.server()) :: map()
  def freshness(server \\ __MODULE__), do: GenServer.call(server, :freshness)

  @doc false
  @spec projection_checkpoint(GenServer.server()) :: %{run_id: String.t(), checkpoint: map() | nil}
  def projection_checkpoint(server \\ __MODULE__), do: GenServer.call(server, :projection_checkpoint)

  @doc false
  @spec put_projection_checkpoint(String.t(), map(), GenServer.server()) ::
          :ok | {:error, :different_run}
  def put_projection_checkpoint(run_id, checkpoint, server \\ __MODULE__)
      when is_binary(run_id) and is_map(checkpoint) do
    GenServer.call(server, {:put_projection_checkpoint, run_id, checkpoint})
  end

  @spec mark_reconciled(:fresh | :unavailable, GenServer.server()) :: :ok
  def mark_reconciled(status, server \\ __MODULE__) when status in [:fresh, :unavailable] do
    GenServer.call(server, {:mark_reconciled, status})
  end

  @spec set_terminal_verification_pending(TrackerIdentity.t(), boolean(), GenServer.server()) :: :ok | {:error, :terminal_verification_marker_failed}
  def set_terminal_verification_pending(identity, pending?, server \\ __MODULE__)
      when is_struct(identity, TrackerIdentity) and is_boolean(pending?) do
    GenServer.call(server, {:set_terminal_verification_pending, identity, pending?})
  end

  @impl true
  def init(opts) do
    run_id = Keyword.get(opts, :run_id, Boot.run_id())
    persistence = Recovery.options(opts)

    state =
      case Recovery.state_dir(opts) do
        {:ok, root} -> Recovery.boot(root, run_id, persistence)
        {:error, reason} -> Recovery.unavailable_state(run_id, persistence, {:path_unresolved, reason})
      end

    state = Map.put(state, :projection_checkpoint, nil)
    Runtime.notify(state, nil)
    {:ok, state}
  end

  @impl true
  def handle_call({:observe, _identity, _lifecycle, _observed_at, _source}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:membership_unavailable, state.health}}, state}
  end

  def handle_call({:observe, identity, lifecycle, observed_at, source}, _from, state) do
    case Event.new(state.run_id, identity, lifecycle, observed_at, source: source) do
      {:ok, event} -> Runtime.handle_observation(event, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:snapshot, limit}, _from, state), do: {:reply, Runtime.snapshot(state, limit), state}

  def handle_call({:lookup, identity}, _from, state) do
    case Projection.member(state.projection, identity) do
      nil -> {:reply, {:error, :not_found}, state}
      member -> {:reply, {:ok, member}, state}
    end
  end

  def handle_call(:generation, _from, state), do: {:reply, state.projection.generation, state}
  def handle_call(:health, _from, state), do: {:reply, state.health, state}
  def handle_call(:freshness, _from, state), do: {:reply, Runtime.freshness(state), state}

  def handle_call(:projection_checkpoint, _from, state) do
    {:reply, %{run_id: state.run_id, checkpoint: state.projection_checkpoint}, state}
  end

  def handle_call({:put_projection_checkpoint, run_id, checkpoint}, _from, state) do
    if run_id == state.run_id do
      {:reply, :ok, Map.put(state, :projection_checkpoint, checkpoint)}
    else
      {:reply, {:error, :different_run}, state}
    end
  end

  def handle_call({:mark_reconciled, status}, _from, state) do
    {:reply, :ok, Runtime.mark_reconciled(state, status)}
  end

  def handle_call({:set_terminal_verification_pending, identity, pending?}, _from, state) do
    case Runtime.set_terminal_verification_pending(state, identity, pending?) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end
end

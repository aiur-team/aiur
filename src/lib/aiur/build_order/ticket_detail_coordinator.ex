defmodule Aiur.BuildOrder.TicketDetailCoordinator do
  @moduledoc """
  Supervised coordinator for configured-repository ticket detail reads.

  This replaces Build Order's own private ticket-detail cache, and the rename is
  the point of the change rather than decoration. Aiur had grown five
  independent GitHub caches, one per reader,
  and each new reader reached for the nearest one and then grew a sixth. A module
  called a cache invites that. This one is not one any more:

    * **GitHub responses are not held here.** The issue body lives in
      `Aiur.GitHub.ResourceStore`, keyed by the issue's identity, so the tracker's
      dispatch poll and this page share one entry instead of fetching the same
      URL into two. Deciding whether to spend an upstream read is the store's job.
    * **What is held here is derived and local**: the sanitized `Snapshot` each
      subscriber last rendered, who is subscribed, which refresh is inflight, and
      which configuration generation it belongs to. None of that is re-fetchable
      from GitHub, because none of it came from GitHub.

  The freshness setting reaches both layers, and means the same thing in each: it
  is one requirement, applied once to whether a re-render is needed and once to
  whether an upstream read is. Two numbers here would be two policies.

  Snapshots are deliberately in-memory. After restart a ticket stays unavailable
  until a fresh read succeeds — but that read is now usually a `304`, or no
  request at all, because the store's validators outlive the restart.
  """

  use GenServer

  alias Aiur.BuildOrder.TicketDetail
  alias Aiur.BuildOrder.TicketDetail.{Failure, State}
  alias Aiur.BuildOrder.TicketDetailCoordinator.{Configuration, Options, Policy, TaskLifecycle}
  alias Aiur.GitHub.RequestOrigin

  @reset_topic "build_order:ticket_detail_coordinator:reset"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec request(GenServer.server(), Aiur.TrackerIdentity.t()) :: {:ok, State.t()} | {:error, Failure.t()}
  def request(server \\ __MODULE__, identity),
    do: GenServer.call(server, {:request, identity, RequestOrigin.view_originated?()})

  @spec current(GenServer.server(), Aiur.TrackerIdentity.t()) :: {:ok, State.t()} | {:error, Failure.t()}
  def current(server \\ __MODULE__, identity), do: GenServer.call(server, {:current, identity})

  @spec subscribe(GenServer.server(), Aiur.TrackerIdentity.t()) :: :ok | {:error, Failure.t() | term()}
  def subscribe(server \\ __MODULE__, identity) do
    with {:ok, topic} <- GenServer.call(server, {:subscription_topic, identity}),
         :ok <- Phoenix.PubSub.subscribe(Aiur.PubSub, topic),
         do: Phoenix.PubSub.subscribe(Aiur.PubSub, reset_topic())
  end

  @spec topic(Aiur.TrackerIdentity.t()) :: String.t()
  defdelegate topic(identity), to: Policy

  @spec reset_topic() :: String.t()
  def reset_topic, do: @reset_topic

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    state = Options.new(opts)
    subscribe_to_configuration(state)
    broadcast_reset(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:request, identity, view_originated?}, _from, state) do
    case authorize(state, identity) do
      {:error, %Failure{} = failure, state, updates} ->
        broadcast_all(updates)
        {:reply, {:error, failure}, state}

      {:ok, identity, repository, state, updates} ->
        request_detail(state, identity, repository, updates, view_originated?)
    end
  end

  def handle_call({:current, identity}, _from, state), do: read_current(state, identity)
  def handle_call({:subscription_topic, identity}, _from, state), do: subscription_topic(state, identity)

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {state, updates} = reconcile_then_complete(state, ref, result)
    broadcast_all(updates)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_reference(ref) do
    {state, updates} = reconcile_then_complete(state, ref, {:error, %Failure{kind: :transport}})
    broadcast_all(updates)
    {:noreply, state}
  end

  def handle_info({:refresh_timeout, ref, generation}, state) when is_reference(ref) and is_integer(generation) do
    {state, updates} = reconcile_then_timeout(state, ref, generation)
    broadcast_all(updates)
    {:noreply, state}
  end

  def handle_info({:workflow_config_updated, generation}, state) do
    {state, updates} = reconcile_for_message(state, generation)
    broadcast_all(updates)
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp read_current(state, identity) do
    case authorize(state, identity) do
      {:error, %Failure{} = failure, state, updates} ->
        broadcast_all(updates)
        {:reply, {:error, failure}, state}

      {:ok, identity, _repository, state, updates} ->
        broadcast_all(updates)
        {:reply, {:ok, Policy.current(state, identity)}, state}
    end
  end

  defp request_detail(state, identity, repository, updates, view_originated?) do
    case Policy.ensure_entry(state, identity) do
      {:error, %Failure{} = failure} ->
        broadcast_all(updates)
        {:reply, {:error, failure}, state}

      {:ok, state, evictions} ->
        broadcast_all(updates ++ evictions)
        {entry, state} = Policy.touch(state, identity)
        refresh_or_reply(entry, state, repository, view_originated?)
    end
  end

  defp refresh_or_reply(entry, state, repository, view_originated?) do
    if Policy.fresh?(entry, state) or entry.inflight do
      {:reply, {:ok, Policy.state_for(entry, state)}, state}
    else
      {entry, state, updates} = TaskLifecycle.start_refresh(entry, state, repository, view_originated?)
      broadcast_all(updates)
      {:reply, {:ok, Policy.state_for(entry, state)}, state}
    end
  end

  defp subscription_topic(state, identity) do
    case authorize(state, identity) do
      {:error, %Failure{} = failure, state, updates} ->
        broadcast_all(updates)
        {:reply, {:error, failure}, state}

      {:ok, identity, _repository, state, updates} ->
        broadcast_all(updates)
        {:reply, {:ok, topic(identity)}, state}
    end
  end

  defp reconcile_then_complete(state, ref, result) do
    {state, reconciliation_updates} = reconcile_for_message(state)
    {state, completion_updates} = TaskLifecycle.apply_completion(ref, result, state)
    {state, reconciliation_updates ++ completion_updates}
  end

  defp reconcile_then_timeout(state, ref, generation) do
    {state, reconciliation_updates} = reconcile_for_message(state)
    {state, timeout_updates} = TaskLifecycle.timeout_refresh(ref, generation, state)
    {state, reconciliation_updates ++ timeout_updates}
  end

  defp reconcile_for_message(state, notified_generation \\ nil) do
    case Configuration.reconcile(state, notified_generation) do
      {:ok, _repository, state, updates} -> {state, updates}
      {:error, _failure, state, updates} -> {state, updates}
    end
  end

  defp reconcile_repository(state) do
    Configuration.reconcile(state)
  end

  defp authorize(state, identity) do
    case reconcile_repository(state) do
      {:error, %Failure{} = failure, state, updates} ->
        {:error, failure, state, updates}

      {:ok, repository, state, updates} ->
        case TicketDetail.fetchable_identity(identity, configured_repo: repository) do
          {:ok, identity, ^repository} -> {:ok, identity, repository, state, updates}
          {:error, %Failure{} = failure} -> {:error, failure, state, updates}
        end
    end
  end

  defp broadcast_all(states), do: Enum.each(states, &broadcast_state/1)

  defp broadcast_state(snapshot) do
    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, topic(snapshot.identity), {:ticket_detail_updated, snapshot})
    end
  end

  defp subscribe_to_configuration(state) do
    state.configuration_subscriber.(self())
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp broadcast_reset(state) do
    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, reset_topic(), {:ticket_detail_coordinator_reset, state.reset_epoch})
    end
  end
end

defmodule Aiur.BuildOrder.TicketDetailCache do
  @moduledoc """
  Supervised, bounded cache for configured-repository ticket detail.

  The cache is deliberately in-memory. After restart, a ticket remains
  unavailable until a newly requested, complete detail read succeeds.
  """

  use GenServer

  alias Aiur.BuildOrder.TicketDetail
  alias Aiur.BuildOrder.TicketDetail.{Failure, State}
  alias Aiur.BuildOrder.TicketDetail.Repository
  alias Aiur.BuildOrder.TicketDetailCache.{Options, Policy, TaskLifecycle}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec request(GenServer.server(), Aiur.TrackerIdentity.t()) :: {:ok, State.t()} | {:error, Failure.t()}
  def request(server \\ __MODULE__, identity), do: GenServer.call(server, {:request, identity})

  @spec current(GenServer.server(), Aiur.TrackerIdentity.t()) :: {:ok, State.t()} | {:error, Failure.t()}
  def current(server \\ __MODULE__, identity), do: GenServer.call(server, {:current, identity})

  @spec subscribe(GenServer.server(), Aiur.TrackerIdentity.t()) :: :ok | {:error, Failure.t() | term()}
  def subscribe(server \\ __MODULE__, identity) do
    with {:ok, topic} <- GenServer.call(server, {:subscription_topic, identity}),
         do: Phoenix.PubSub.subscribe(Aiur.PubSub, topic)
  end

  @spec topic(Aiur.TrackerIdentity.t()) :: String.t()
  defdelegate topic(identity), to: Policy

  @impl true
  def init(opts), do: {:ok, Options.new(opts)}

  @impl true
  def handle_call({:request, identity}, _from, state) do
    case authorize(state, identity) do
      {:error, %Failure{} = failure, state, updates} ->
        broadcast_all(updates)
        {:reply, {:error, failure}, state}

      {:ok, identity, repository, state, updates} ->
        request_detail(state, identity, repository, updates)
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

  defp request_detail(state, identity, repository, updates) do
    case Policy.ensure_entry(state, identity) do
      {:error, %Failure{} = failure} ->
        broadcast_all(updates)
        {:reply, {:error, failure}, state}

      {:ok, state, evictions} ->
        broadcast_all(updates ++ evictions)
        {entry, state} = Policy.touch(state, identity)
        refresh_or_reply(entry, state, repository)
    end
  end

  defp refresh_or_reply(entry, state, repository) do
    if Policy.fresh?(entry, state) or entry.inflight do
      {:reply, {:ok, Policy.state_for(entry, state)}, state}
    else
      {entry, state, updates} = TaskLifecycle.start_refresh(entry, state, repository)
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

  defp reconcile_for_message(state) do
    case reconcile_repository(state) do
      {:ok, _repository, state, updates} -> {state, updates}
      {:error, _failure, state, updates} -> {state, updates}
    end
  end

  defp reconcile_repository(state) do
    case TicketDetail.configured_repository(detail_opts(state)) do
      {:ok, repository} ->
        {state, updates} = reset_if_repository_changed(state, repository)
        {:ok, repository, state, updates}

      {:error, %Failure{} = failure} ->
        {state, updates} = reset_if_repository_changed(state, :unavailable)
        {:error, failure, state, updates}
    end
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

  defp reset_if_repository_changed(%{active_repository: active_repository} = state, repository) do
    if active_repository == repository or repositories_match?(active_repository, repository) do
      {state, []}
    else
      state = TaskLifecycle.cancel_all(state)
      {state, updates} = Policy.evict_all(state)
      {%{state | active_repository: repository}, updates}
    end
  end

  defp repositories_match?({_, _} = left, {_, _} = right), do: Repository.same_repository?(left, right)
  defp repositories_match?(_left, _right), do: false

  defp detail_opts(%{configured_repo: nil}), do: []
  defp detail_opts(%{configured_repo: configured_repo}), do: [configured_repo: configured_repo]

  defp broadcast_all(states), do: Enum.each(states, &broadcast_state/1)

  defp broadcast_state(snapshot) do
    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, topic(snapshot.identity), {:ticket_detail_updated, snapshot})
    end
  end
end

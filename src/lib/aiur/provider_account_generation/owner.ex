defmodule Aiur.ProviderAccountGeneration.Owner do
  @moduledoc false

  use GenServer

  alias Aiur.ProviderAccountGeneration.{Events, State}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name, Aiur.ProviderAccountGeneration) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts), do: {:ok, State.new(opts)}

  @impl true
  def handle_call({:lookup, provider, backend, binding}, _from, state), do: {:reply, State.lookup(state, provider, backend, binding), state}

  def handle_call({:issue_binding, provider, backend}, from, state) do
    case State.issue(state, provider, backend, caller_pid(from)) do
      {:ok, binding, state} -> {:reply, {:ok, binding}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:recover_binding, provider, backend, binding, authority, topic}, from, state) do
    case State.recover(state, provider, backend, binding, authority, topic, caller_pid(from)) do
      {:ok, changes, state} ->
        Events.broadcast(changes)
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :owner_unavailable}, state}
    end
  end

  def handle_call({:subscription_topic, provider, backend, binding}, _from, state),
    do: {:reply, State.subscription(state, provider, backend, binding), state}

  def handle_call({:confirm, provider, backend, binding, opts}, _from, state) do
    {snapshot, state} = State.confirm(state, provider, backend, binding, opts)
    {:reply, {:ok, snapshot}, state}
  end

  def handle_call({action, provider, backend, binding, opts}, from, state) when action in [:bind, :replace, :invalidate, :retire] do
    {snapshot, changes, state} = transition(action, state, provider, backend, binding, opts, caller_pid(from))
    Events.broadcast(changes)
    {:reply, {:ok, snapshot}, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {changes, state} = State.owner_down(state, monitor)
    Events.broadcast(changes)
    {:noreply, state}
  end

  defp transition(:bind, state, provider, backend, binding, opts, owner_pid), do: State.bind(state, provider, backend, binding, opts, owner_pid)
  defp transition(:replace, state, provider, backend, binding, opts, owner_pid), do: State.replace(state, provider, backend, binding, opts, owner_pid)
  defp transition(:invalidate, state, provider, backend, binding, opts, owner_pid), do: State.invalidate(state, provider, backend, binding, opts, owner_pid)
  defp transition(:retire, state, provider, backend, binding, opts, owner_pid), do: State.retire(state, provider, backend, binding, opts, owner_pid)
  defp caller_pid({pid, _tag}) when is_pid(pid), do: pid
end

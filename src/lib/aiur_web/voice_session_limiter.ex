defmodule AiurWeb.VoiceSessionLimiter do
  @moduledoc """
  Bounds concurrent dashboard dictation and conversation sessions.

  A signed dashboard connection may own at most two sessions (for a brief tab
  handoff), while the daemon admits at most eight in total. Owner monitors make
  leases self-releasing when their owning channel or conversation exits.
  """

  use GenServer

  @max_per_authority 2
  @max_global 8

  @type lease :: reference()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec acquire(String.t(), pid()) :: {:ok, lease()} | {:error, :capacity}
  def acquire(authority, owner \\ self()) when is_binary(authority) and is_pid(owner) do
    GenServer.call(__MODULE__, {:acquire, authority, owner})
  end

  @doc "Reuses a conversation-owned lease when its transport reconnects."
  @spec acquire_session(String.t(), pid()) :: {:ok, lease()} | {:error, :capacity}
  def acquire_session(authority, owner), do: GenServer.call(__MODULE__, {:acquire_session, authority, owner})

  @doc "Moves an admitted transport lease to its long-lived conversation process."
  @spec transfer(lease(), pid()) :: :ok
  def transfer(lease, owner), do: GenServer.call(__MODULE__, {:transfer, lease, owner})

  @spec release(lease()) :: :ok
  def release(lease) when is_reference(lease) do
    GenServer.call(__MODULE__, {:release, lease})
  end

  @impl true
  def init(_opts), do: {:ok, %{leases: %{}}}

  @impl true
  def handle_call({:acquire, authority, owner}, _from, state) do
    authority_count = Enum.count(state.leases, fn {_lease, entry} -> entry.authority == authority end)

    if map_size(state.leases) >= @max_global or authority_count >= @max_per_authority do
      {:reply, {:error, :capacity}, state}
    else
      lease = make_ref()
      monitor = Process.monitor(owner)
      entry = %{authority: authority, monitor: monitor, owner: owner}
      {:reply, {:ok, lease}, put_in(state, [:leases, lease], entry)}
    end
  end

  def handle_call({:acquire_session, authority, owner}, from, state) do
    case Enum.find(state.leases, fn {_lease, entry} -> entry.authority == authority and entry.owner == owner end) do
      {lease, _} -> {:reply, {:ok, lease}, state}
      nil -> handle_call({:acquire, authority, owner}, from, state)
    end
  end

  def handle_call({:transfer, lease, owner}, _from, state) do
    case Map.fetch(state.leases, lease) do
      {:ok, entry} -> {:reply, :ok, transfer_owner(state, lease, entry, owner)}
      :error -> {:reply, :ok, state}
    end
  end

  def handle_call({:release, lease}, _from, state) do
    {:reply, :ok, release_lease(state, lease)}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    lease = Enum.find_value(state.leases, fn {lease, entry} -> if entry.monitor == monitor, do: lease end)
    {:noreply, release_lease(state, lease)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp transfer_owner(state, lease, entry, owner) do
    duplicate? = Enum.any?(state.leases, fn {key, other} -> key != lease and other.authority == entry.authority and other.owner == owner end)

    if duplicate? do
      release_lease(state, lease)
    else
      Process.demonitor(entry.monitor, [:flush])
      put_in(state, [:leases, lease], %{entry | owner: owner, monitor: Process.monitor(owner)})
    end
  end

  defp release_lease(state, nil), do: state

  defp release_lease(state, lease) do
    case Map.pop(state.leases, lease) do
      {nil, _leases} ->
        state

      {entry, leases} ->
        Process.demonitor(entry.monitor, [:flush])
        %{state | leases: leases}
    end
  end
end

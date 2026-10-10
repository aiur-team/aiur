defmodule Aiur.Opencode.SlotPolicyFakes do
  @moduledoc false

  alias Aiur.Opencode.SlotRegistry

  defmodule FakeSlot do
    @moduledoc false

    use GenServer

    alias Aiur.Opencode.SlotRegistry

    def start_link(slot_index), do: GenServer.start_link(__MODULE__, slot_index)

    @impl true
    def init(slot_index) do
      :ok = SlotRegistry.register_self(slot_index)
      {:ok, %{slot_index: slot_index, status: :active}}
    end

    @impl true
    def handle_call(:snapshot, _from, state) do
      {:reply, %{status: state.status}, state}
    end
  end

  defmodule FakeSlotStarter do
    @moduledoc false

    def start_slot(slot_index), do: FakeSlot.start_link(slot_index)
  end

  defmodule ReplacingSlotStarter do
    @moduledoc false

    def start_slot(slot_index) do
      case SlotRegistry.lookup(slot_index) do
        {:ok, pid} -> {:ok, pid}
        :not_found -> FakeSlot.start_link(slot_index)
      end
    end
  end

  defmodule RecordingSlotStopper do
    @moduledoc false

    def stop_slot(_slot_index), do: :ok
  end

  defmodule BusyHighestSlotStopper do
    @moduledoc false

    def stop_slot(3), do: :busy
    def stop_slot(_slot_index), do: :ok
  end

  defmodule BlockingSlotStarter do
    @moduledoc false

    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid, name: __MODULE__)

    def start_slot(slot_index) do
      GenServer.call(__MODULE__, {:start_slot, slot_index}, :infinity)
    end

    def release do
      GenServer.call(__MODULE__, :release)
    end

    @impl true
    def init(test_pid) do
      {:ok, %{test_pid: test_pid, pending_start: nil}}
    end

    @impl true
    def handle_call({:start_slot, slot_index}, from, %{pending_start: nil} = state) do
      send(state.test_pid, {:slot_start_blocked, slot_index})
      {:noreply, %{state | pending_start: from}}
    end

    def handle_call(:release, _from, %{pending_start: pending_start} = state)
        when not is_nil(pending_start) do
      GenServer.reply(pending_start, {:error, :released})
      {:reply, :ok, %{state | pending_start: nil}}
    end
  end
end

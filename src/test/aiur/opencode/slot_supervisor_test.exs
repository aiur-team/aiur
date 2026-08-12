defmodule Aiur.Opencode.SlotSupervisorTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.{Slot, SlotPolicy, SlotRegistry, SlotSupervisor}

  defmodule FakeActiveSlot do
    use GenServer

    def start_link(slot_index), do: GenServer.start_link(__MODULE__, slot_index)

    @impl true
    def init(slot_index) do
      :ok = SlotRegistry.register_self(slot_index)
      {:ok, :active}
    end

    @impl true
    def handle_call(:snapshot, _from, status), do: {:reply, %{status: status}, status}
  end

  defmodule FakeSlotStarter do
    def start_slot(slot_index), do: FakeActiveSlot.start_link(slot_index)
  end

  defmodule ClaimableSlot do
    use GenServer

    def start_link(index), do: GenServer.start_link(__MODULE__, index)

    @impl true
    def init(index) do
      :ok = SlotRegistry.register_self(index)
      {:ok, %{status: :ready, claim_owner: nil, claim_ref: nil}}
    end

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, %{status: state.status}, state}

    def handle_call({:claim_ready, owner}, _from, %{status: :ready} = state) do
      ref = Process.monitor(owner)
      {:reply, :ok, %{state | status: :claimed, claim_owner: owner, claim_ref: ref}}
    end

    def handle_call({:claim_ready, _owner}, _from, state), do: {:reply, :busy, state}
    def handle_call(:reserve_stop, _from, %{status: :ready} = state), do: {:reply, :ok, %{state | status: :stopping}}
    def handle_call(:reserve_stop, _from, state), do: {:reply, :busy, state}

    @impl true
    def handle_info({:DOWN, ref, :process, owner, _}, %{claim_ref: ref, claim_owner: owner} = state),
      do: {:noreply, %{state | status: :ready, claim_owner: nil, claim_ref: nil}}
  end

  describe "acquire_slot/0 with no registered slots" do
    test "returns :no_ready_slot" do
      assert SlotSupervisor.acquire_slot() == {:error, :no_ready_slot}
    end
  end

  describe "acquire_slot/0 claim coordination" do
    test "a claimed slot cannot be reserved for termination" do
      {:ok, pid} = ClaimableSlot.start_link(1)
      Process.unlink(pid)

      assert {1, ^pid} = SlotSupervisor.acquire_slot()
      assert :busy = Slot.reserve_stop(pid)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "a dead claimant releases a real slot for reacquisition" do
      {:ok, pid} = ClaimableSlot.start_link(1)
      Process.unlink(pid)

      owner = self()
      claimant = spawn(fn -> send(owner, {:claimed, SlotSupervisor.acquire_slot()}) end)
      assert_receive {:claimed, {1, ^pid}}
      Process.exit(claimant, :kill)

      assert_reserve_stop(pid)
      GenServer.stop(pid)
    end
  end

  describe "slot_count/0 with no registered slots" do
    test "returns zero" do
      assert SlotSupervisor.slot_count() == 0
    end
  end

  describe "acquire_slot_or_grow/0 with no registered slots" do
    test "returns :no_ready_slot (growth is best-effort, never the caller's result)" do
      assert SlotSupervisor.acquire_slot_or_grow() == {:error, :no_ready_slot}
    end
  end

  describe "acquire_slot_or_grow/0 with a consumed slot" do
    test "delegates growth to the globally registered slot policy" do
      policy =
        start_supervised!({SlotPolicy, target_count: 1, max_slots: 2, pubsub: Aiur.PubSub, slot_starter: FakeSlotStarter})

      assert SlotPolicy.highest_started(policy) == 1
      assert [{1, _slot_pid}] = SlotRegistry.all()

      assert SlotSupervisor.acquire_slot_or_grow() == {:error, :no_ready_slot}
      assert SlotPolicy.highest_started(policy) == 2
      assert registered_slot_indexes() == [1, 2]

      assert :ok = stop_supervised(SlotPolicy)
      assert_empty_slot_registry()
    end
  end

  defp registered_slot_indexes do
    SlotRegistry.all()
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp assert_reserve_stop(pid, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_reserve_stop(pid, deadline)
  end

  defp wait_for_reserve_stop(pid, deadline) do
    case Slot.reserve_stop(pid) do
      :ok ->
        :ok

      :busy ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("slot ownership was not released before the deadline")
        end

        Process.sleep(10)
        wait_for_reserve_stop(pid, deadline)
    end
  end

  defp assert_empty_slot_registry(timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_empty_slot_registry(deadline)
  end

  defp wait_for_empty_slot_registry(deadline) do
    cond do
      Registry.count(SlotRegistry.registry_name()) == 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("slot registry did not clear after stopping the test policy")

      true ->
        Process.sleep(10)
        wait_for_empty_slot_registry(deadline)
    end
  end
end

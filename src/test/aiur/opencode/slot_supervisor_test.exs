defmodule Aiur.Opencode.SlotSupervisorTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.{Slot, SlotRegistry, SlotSupervisor}

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
      Process.sleep(20)

      assert :ok = Slot.reserve_stop(pid)
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
end

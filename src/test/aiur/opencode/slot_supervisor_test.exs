defmodule Aiur.Opencode.SlotSupervisorTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.{SlotRegistry, SlotSupervisor}

  defmodule ClaimableSlot do
    use GenServer

    def start_link(index), do: GenServer.start_link(__MODULE__, index)

    @impl true
    def init(index) do
      :ok = SlotRegistry.register_self(index)
      {:ok, :ready}
    end

    @impl true
    def handle_call(:snapshot, _from, status), do: {:reply, %{status: status}, status}
    def handle_call(:claim_ready, _from, :ready), do: {:reply, :ok, :claimed}
    def handle_call(:claim_ready, _from, status), do: {:reply, :busy, status}
    def handle_call(:reserve_stop, _from, :ready), do: {:reply, :ok, :stopping}
    def handle_call(:reserve_stop, _from, status), do: {:reply, :busy, status}
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
      assert :busy = Aiur.Opencode.Slot.reserve_stop(pid)
      assert Process.alive?(pid)

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

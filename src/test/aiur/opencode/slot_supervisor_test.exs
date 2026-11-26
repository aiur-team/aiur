defmodule Aiur.Opencode.SlotSupervisorTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.{Slot, SlotPolicy, SlotRegistry, SlotSupervisor}

  setup context do
    if context[:stopped_slot_registry] do
      ensure_slot_registry!()
      :ok = Supervisor.terminate_child(Aiur.Supervisor, SlotRegistry.registry_name())
      on_exit(fn -> ensure_slot_registry!() end)
      assert Process.whereis(SlotRegistry.registry_name()) == nil
    end

    if context[:leftover_slot], do: start_leftover_slot!(1)

    :ok
  end

  setup context do
    ensure_slot_registry!()
    stop_leftover_slots!(!context[:leftover_slot])
  end

  defmodule FakeActiveSlot do
    use GenServer

    def start_link(slot_index), do: GenServer.start_link(__MODULE__, slot_index)

    @impl true
    def init(slot_index) do
      # Linked to the policy, so a failed start kills it: carry the index owner in the exit reason.
      case SlotRegistry.register_self(slot_index) do
        :ok -> {:ok, :active}
        error -> {:stop, {error, SlotRegistry.lookup(slot_index), Process.whereis(SlotRegistry.registry_name())}}
      end
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
      assert_receive {:claimed, {1, ^pid}}, 1000
      Process.exit(claimant, :kill)

      assert_reserve_stop(pid)
      GenServer.stop(pid)
    end
  end

  describe "slot_count/0 with no registered slots" do
    @tag :stopped_slot_registry
    test "returns zero after a sibling stopped the application-owned registry" do
      assert SlotSupervisor.slot_count() == 0
    end
  end

  describe "acquire_slot_or_grow/0 with no registered slots" do
    test "returns :no_ready_slot (growth is best-effort, never the caller's result)" do
      assert SlotSupervisor.acquire_slot_or_grow() == {:error, :no_ready_slot}
    end
  end

  describe "acquire_slot_or_grow/0 with a consumed slot" do
    # #5162: a live index-1 holder makes the policy's slot-1 start crash, which
    # kills the linked policy and reads as highest_started == 0.
    @tag :leftover_slot
    test "grows even when a prior test left a live slot registered at index 1" do
      assert_grows_through_global_policy()
    end

    test "delegates growth to the globally registered slot policy" do
      assert_grows_through_global_policy()
    end
  end

  defp assert_grows_through_global_policy do
    pubsub = Module.concat(__MODULE__, "PubSub#{System.unique_integer([:positive, :monotonic])}")
    start_supervised!({Phoenix.PubSub, name: pubsub}, id: {Phoenix.PubSub, pubsub})

    policy =
      start_supervised!({SlotPolicy, target_count: 1, max_slots: 2, pubsub: pubsub, slot_starter: FakeSlotStarter})

    ref = Process.monitor(policy)
    # highest_started/1 reads a dead or slow policy as 0. Call directly so a
    # failure shows the exit reason or the timeout; a policy already dead
    # before the monitor shows only :noproc.
    started = GenServer.call(policy, :highest_started, 5_000)
    refute_received {:DOWN, ^ref, :process, ^policy, _reason}
    assert started == 1
    assert [{1, _slot_pid}] = SlotRegistry.all()

    assert SlotSupervisor.acquire_slot_or_grow() == {:error, :no_ready_slot}
    assert GenServer.call(policy, :highest_started, 5_000) == 2
    assert registered_slot_indexes() == [1, 2]

    assert :ok = stop_supervised(SlotPolicy)
    assert_empty_slot_registry()
  end

  defp start_leftover_slot!(index) do
    ensure_slot_registry!()
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        :ok = SlotRegistry.register_self(index)
        send(parent, {ref, :registered})
        receive do: (:stop -> :ok)
      end)

    assert_receive {^ref, :registered}, 1_000
    on_exit(fn -> Process.exit(pid, :kill) end)
  end

  # The SlotRegistry is application-global: kill any slot an earlier test left
  # alive so this test owns every index it registers. The warning names the
  # leaker's ancestry so a CI log identifies it (#5162).
  defp stop_leftover_slots!(report?) do
    for {index, pid} <- SlotRegistry.all() do
      if report?, do: IO.warn("SlotSupervisorTest killing leftover slot #{index}: #{inspect(Process.info(pid, [:initial_call, :dictionary]))}", [])
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end

    :ok
  end

  defp ensure_slot_registry! do
    :ok = Aiur.TestSupport.ensure_runtime_children_running()

    # The supervisor call waits for any rest_for_one cascade before inspecting the child.
    children = Supervisor.which_children(Aiur.Supervisor)
    name = SlotRegistry.registry_name()

    if List.keyfind(children, name, 0) |> elem(1) == :undefined do
      assert {:ok, _pid} = Supervisor.restart_child(Aiur.Supervisor, name)
    end

    :ok
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

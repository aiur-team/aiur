defmodule Aiur.Opencode.SlotPolicyTest do
  use Aiur.TestSupport

  alias Aiur.Opencode.{Slot, SlotPolicy, SlotRegistry, SlotSupervisor}

  @policy_startup_timeout 5_000
  @registry_cleanup_timeout 2_000

  # SlotPolicy interacts with SlotSupervisor and the real PubSub. The
  # unit-test goal here is to verify the lazy-expansion + bump logic
  # via PubSub messages and the public API without spinning up real
  # Slot workers (which would require opencode-serve + tmux).
  #
  # We bypass SlotSupervisor.start_slot by setting target_count=0 to
  # prove the skip path; for real chain advance behavior, integration
  # coverage happens in U11 e2e + manual CLI verification.

  defmodule FakeSlot do
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
    def start_slot(slot_index), do: FakeSlot.start_link(slot_index)
  end

  defmodule BlockingSlotStarter do
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

  setup do
    stop_registered_slots()

    unique = System.unique_integer([:positive, :monotonic])
    policy_name = Module.concat(__MODULE__, "Policy#{unique}")
    pubsub = Module.concat(__MODULE__, "PubSub#{unique}")

    start_supervised!({Phoenix.PubSub, name: pubsub}, id: {Phoenix.PubSub, pubsub})

    on_exit(&stop_registered_slots/0)

    {:ok, policy_name: policy_name, pubsub: pubsub}
  end

  describe "init/1 with target_count=0" do
    test "skips starting any slot", %{policy_name: name, pubsub: pubsub} do
      pid = start_policy!(name, pubsub, target_count: 0)

      assert Process.alive?(pid)
      assert SlotPolicy.highest_started(pid) == 0
      assert SlotPolicy.target_count(pid) == 0
    end
  end

  describe "PubSub topic subscription" do
    test "subscribes to the Slot slots_topic and tolerates noise", %{
      policy_name: name,
      pubsub: pubsub
    } do
      pid = start_policy!(name, pubsub, target_count: 0)

      topic = Slot.slots_topic()
      :ok = Phoenix.PubSub.subscribe(pubsub, topic)

      Phoenix.PubSub.broadcast(pubsub, topic, {:slot_ready, 99})
      Phoenix.PubSub.broadcast(pubsub, topic, {:slot_session_changed, 1, "issue-42"})
      Phoenix.PubSub.broadcast(pubsub, topic, {:slot_attach_added, 1, "issue-1"})
      Phoenix.PubSub.broadcast(pubsub, topic, {:slot_attach_removed, 1, "issue-1"})
      Phoenix.PubSub.broadcast(pubsub, topic, {:slot_visible_changed, 1, nil})
      Phoenix.PubSub.broadcast(pubsub, topic, {:slot_policy_test_sync, self()})

      assert_receive {:slot_policy_test_sync, _}, 2_000
      :sys.get_state(pid)
      assert Process.alive?(pid)
    end
  end

  describe "bump/0 with target_count=0" do
    test "is a safe no-op", %{policy_name: name, pubsub: pubsub} do
      pid = start_policy!(name, pubsub, target_count: 0)

      assert :ok = SlotPolicy.bump(pid)
      assert SlotPolicy.highest_started(pid) == 0
    end

    test "tolerates a dead server pid" do
      dead = dead_pid()

      assert :ok = SlotPolicy.bump(dead)
    end
  end

  describe "highest_started/0 + target_count/0 introspection" do
    test "report the configured target and starting highest of 0", %{
      policy_name: name,
      pubsub: pubsub
    } do
      pid = start_policy!(name, pubsub, target_count: 0)

      assert SlotPolicy.target_count(pid) == 0
      assert SlotPolicy.highest_started(pid) == 0
    end

    test "return safe defaults on a dead pid" do
      dead = dead_pid()

      assert SlotPolicy.highest_started(dead) == 0
      assert SlotPolicy.target_count(dead) == 0
    end

    test "reports fallback zero while startup is busy, then the configured target after release",
         %{policy_name: name, pubsub: pubsub} do
      start_supervised!({BlockingSlotStarter, self()})

      pid =
        start_policy!(name, pubsub,
          target_count: 1,
          max_slots: 1,
          slot_starter: BlockingSlotStarter
        )

      monitor = Process.monitor(pid)

      assert_receive {:slot_start_blocked, 1}, 2_000
      assert Process.alive?(pid)
      assert SlotPolicy.target_count(pid) == 0
      refute_received {:DOWN, ^monitor, :process, ^pid, _reason}
      assert Process.alive?(pid)

      assert :ok = BlockingSlotStarter.release()
      assert %{target_count: 1, highest_started: 0} = await_policy_startup!(pid, 0)
      assert SlotPolicy.target_count(pid) == 1
      assert Process.alive?(pid)

      Process.demonitor(monitor, [:flush])
    end
  end

  describe "max_slots/0 decoupling from target_count" do
    test "warm-pool target and the hard cap are independent", %{policy_name: name, pubsub: pubsub} do
      pid = start_policy!(name, pubsub, target_count: 0, max_slots: 5)

      # pre_warmed_sessions = 0 boots no warm panes...
      assert SlotPolicy.target_count(pid) == 0
      # ...but the pool may still grow on demand up to the hard cap.
      assert SlotPolicy.max_slots(pid) == 5
    end

    test "returns a safe default on a dead pid" do
      dead = dead_pid()

      assert SlotPolicy.max_slots(dead) == 0
    end

    test "config pre_warmed_sessions sizes only target_count while max slots comes from grid and max agents",
         %{policy_name: name, pubsub: pubsub} do
      write_workflow_file!(Workflow.workflow_file_path(),
        max_vertical_panes: 3,
        max_concurrent_agents: 8,
        pre_warmed_sessions: 1
      )

      pid = start_policy!(name, pubsub, slot_starter: FakeSlotStarter)

      assert SlotPolicy.target_count(pid) == 1
      assert SlotPolicy.max_slots(pid) == 8
      assert SlotPolicy.highest_started(pid) == 1
      assert registered_slots() == [1]
    end
  end

  describe "grow_slot/1 ceiling" do
    test "a consumed warm pool grows cold slots on demand up to max_slots", %{pubsub: pubsub} do
      pid =
        start_policy!(SlotPolicy, pubsub,
          target_count: 1,
          max_slots: 8,
          slot_starter: FakeSlotStarter
        )

      assert %{target_count: 1, max_slots: 8, highest_started: 1} =
               await_policy_startup!(pid, 1)

      assert SlotPolicy.target_count(pid) == 1
      assert SlotPolicy.max_slots(pid) == 8
      assert SlotPolicy.highest_started(pid) == 1

      for expected_slot <- 2..8 do
        assert SlotSupervisor.acquire_slot_or_grow() == {:error, :no_ready_slot}
        assert SlotPolicy.highest_started(pid) == expected_slot
      end

      assert registered_slots() == Enum.to_list(1..8)

      assert SlotSupervisor.acquire_slot_or_grow() == {:error, :no_ready_slot}
      assert SlotPolicy.highest_started(pid) == 8
    end

    test "refuses to grow past max_slots", %{policy_name: name, pubsub: pubsub} do
      # target_count == max_slots == 0: the pool is already at its cap,
      # so no on-demand slot may start.
      pid = start_policy!(name, pubsub, target_count: 0, max_slots: 0)

      assert SlotPolicy.grow_slot(pid) == {:error, :at_capacity}
      assert SlotPolicy.highest_started(pid) == 0
    end

    test "tolerates a dead server pid" do
      dead = dead_pid()

      assert SlotPolicy.grow_slot(dead) == {:error, :unavailable}
    end
  end

  describe "stop_registered_slots/0" do
    test "waits for Registry to remove dead slot keys" do
      {:ok, slot} = FakeSlot.start_link(1)
      Process.unlink(slot)

      partitions = registry_partitions()
      assert partitions != []

      Enum.each(partitions, &:sys.suspend/1)
      on_exit(fn -> Enum.each(partitions, &:sys.resume/1) end)

      test_pid = self()

      spawn(fn ->
        Process.sleep(100)
        send(test_pid, :registry_cleanup_released)
        Enum.each(partitions, &:sys.resume/1)
      end)

      stop_registered_slots()

      assert_received :registry_cleanup_released
      assert Registry.lookup(SlotRegistry.registry_name(), 1) == []
    end

    test "fails when Registry does not remove dead slot keys before the timeout" do
      {:ok, slot} = FakeSlot.start_link(1)
      Process.unlink(slot)

      partitions = registry_partitions()
      assert partitions != []

      Enum.each(partitions, &:sys.suspend/1)

      try do
        assert_raise ExUnit.AssertionError,
                     ~r/slot registry did not clear within 25ms: 1 entries remain/,
                     fn -> stop_registered_slots(25) end

        assert Registry.lookup(SlotRegistry.registry_name(), 1) != []
      after
        Enum.each(partitions, &:sys.resume/1)
      end
    end
  end

  defp start_policy!(name, pubsub, opts) do
    opts =
      opts
      |> Keyword.put(:name, name)
      |> Keyword.put(:pubsub, pubsub)

    start_supervised!({SlotPolicy, opts})
  end

  defp await_policy_startup!(pid, expected_highest) do
    monitor = Process.monitor(pid)

    try do
      state = :sys.get_state(pid, @policy_startup_timeout)
      assert state.highest_started == expected_highest
      state
    catch
      :exit, exit_reason ->
        down_reason =
          receive do
            {:DOWN, ^monitor, :process, ^pid, reason} -> reason
          after
            0 -> :policy_still_alive
          end

        flunk(
          "slot policy did not finish startup: " <>
            "alive=#{Process.alive?(pid)} exit=#{inspect(exit_reason)} " <>
            "down=#{inspect(down_reason)}"
        )
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    refute Process.alive?(pid)
    pid
  end

  defp registered_slots do
    SlotRegistry.all()
    |> Enum.map(fn {index, _pid} -> index end)
    |> Enum.sort()
  end

  defp registry_partitions do
    SlotRegistry.registry_name()
    |> Supervisor.which_children()
    |> Enum.map(fn {_id, pid, :worker, [Registry.Partition]} -> pid end)
  end

  defp stop_registered_slots(timeout \\ @registry_cleanup_timeout) do
    for {_index, pid} <- SlotRegistry.all(), Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        1_000 -> flunk("slot process did not stop: #{inspect(pid)}")
      end
    end

    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_registry_cleanup(deadline, timeout)
  end

  defp wait_for_registry_cleanup(deadline, timeout) do
    remaining = Registry.count(SlotRegistry.registry_name())

    cond do
      remaining == 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("slot registry did not clear within #{timeout}ms: #{remaining} entries remain")

      true ->
        Process.sleep(10)
        wait_for_registry_cleanup(deadline, timeout)
    end
  end
end

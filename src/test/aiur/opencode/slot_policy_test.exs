defmodule Aiur.Opencode.SlotPolicyTest do
  use Aiur.TestSupport

  alias Aiur.Opencode.{Slot, SlotPolicy, SlotRegistry, SlotSupervisor}

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
      write_workflow_file!(Workflow.workflow_file_path(),
        max_vertical_panes: 3,
        max_concurrent_agents: 8,
        pre_warmed_sessions: 1
      )

      pid = start_policy!(SlotPolicy, pubsub, slot_starter: FakeSlotStarter)

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

  defp start_policy!(name, pubsub, opts) do
    opts =
      opts
      |> Keyword.put(:name, name)
      |> Keyword.put(:pubsub, pubsub)

    start_supervised!({SlotPolicy, opts})
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

  defp stop_registered_slots do
    for {_index, pid} <- SlotRegistry.all(), Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        1_000 -> flunk("slot process did not stop: #{inspect(pid)}")
      end
    end

    # The Registry processes :DOWN messages async — wait until entries are gone
    # so the next test's FakeSlot.init doesn't see stale registrations.
    Enum.reduce_while(1..40, :ok, fn _, _ ->
      if SlotRegistry.all() == [],
        do: {:halt, :ok},
        else:
          (
            Process.sleep(5)
            {:cont, :ok}
          )
    end)
  end
end

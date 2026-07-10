defmodule Aiur.Regression.OpencodeSlotsTest do
  @moduledoc """
  Characterization of the opencode slot/attach layer (refactor T-011).
  Pins: warm gate before paint (:slot_ready), attach/reclaim under
  churn (#372/#607/#608 TOCTOU class), FD/attach fan-out census
  (#409 :emfile class — docs/measurements/2026-06-23-emfile-structural-fix-census.md),
  and operator-message preservation through the slot lifecycle (#332 class).
  Read-only for executor agents: if one of these tests fails, the
  production change is wrong.
  """

  use ExUnit.Case, async: false

  alias Aiur.Opencode.{AttachPool, Slot, SlotPolicy, SlotRegistry}

  @slot_source Path.expand("../../../lib/aiur/opencode/slot.ex", __DIR__)
  @serve_lifecycle_source Path.expand("../../../lib/aiur/opencode/slot/serve_lifecycle.ex", __DIR__)
  @state_source Path.expand("../../../lib/aiur/opencode/slot/state.ex", __DIR__)

  defmodule RecordingSlot do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      index = Keyword.fetch!(opts, :index)
      test = Keyword.fetch!(opts, :test)
      :ok = SlotRegistry.register_self(index)
      {:ok, %{index: index, test: test, visible: nil}}
    end

    @impl true
    def handle_call({:set_visible, identifier}, _from, state) do
      send(state.test, {:slot_call, :set_visible, state.index, identifier})
      {:reply, {:ok, "%#{state.index}"}, %{state | visible: identifier}}
    end

    def handle_call({:attach, identifier}, _from, state) do
      send(state.test, {:slot_call, :attach, state.index, identifier})
      {:reply, {:ok, :attached}, state}
    end

    def handle_call({:detach, identifier}, _from, state) do
      send(state.test, {:slot_call, :detach, state.index, identifier})
      visible = if state.visible == identifier, do: nil, else: state.visible
      {:reply, :ok, %{state | visible: visible}}
    end

    def handle_call(:snapshot, _from, state) do
      {:reply, %{visible_identifier: state.visible}, state}
    end
  end

  setup do
    {:ok, pool} =
      AttachPool.start_link(name: :"AttachPool_#{System.unique_integer([:positive])}")

    {:ok, pool: pool}
  end

  defp start_slots(test, m) do
    for index <- 1..m do
      {:ok, _} =
        start_supervised({RecordingSlot, [index: index, test: test]}, id: {:slot, index})
    end
  end

  defp announce_ready(indexes) do
    for index <- indexes do
      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_ready, index})
    end
  end

  defp sync(pid), do: :sys.get_state(pid)

  defp pos!(block, needle) do
    {pos, _len} = :binary.match(block, needle)
    pos
  end

  defp extract!(source, regex) do
    case Regex.run(regex, source) do
      [block | _] -> block
      _ -> raise "could not extract block for #{inspect(regex)}"
    end
  end

  describe "warm gate: no paint before :slot_ready" do
    test "seeded identifiers are not painted until the slot broadcasts :slot_ready", %{pool: pool} do
      AttachPool.seed(pool, ["issue-1", "issue-2"])
      sync(pool)
      start_slots(self(), 1)

      refute_receive {:slot_call, _, _, _}, 1000

      announce_ready([1])
      assert_receive {:slot_call, :set_visible, 1, "issue-1"}, 2000
    end

    test "a repeated :slot_ready (rebuild re-ready) never re-fires the rotational leadoff",
         %{pool: pool} do
      AttachPool.seed(pool, ["issue-1", "issue-2"])
      sync(pool)
      start_slots(self(), 1)

      announce_ready([1])
      assert_receive {:slot_call, :set_visible, 1, "issue-1"}, 2000

      announce_ready([1])
      sync(pool)

      refute_receive {:slot_call, :set_visible, 1, _}, 1000, """
      A slot re-broadcasts :slot_ready after schedule_serve_rebuild.
      Re-firing the rotation races in-flight set_visible from do_seed,
      displacing the assignment the user just triggered.
      """
    end
  end

  describe "warmth lifecycle events (4-state marker inputs)" do
    test "first attach flips :slot_fully_warmed exactly once; losing the last attach drops warmth" do
      Phoenix.PubSub.subscribe(Aiur.PubSub, AttachPool.topic())

      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, 1, "issue-1"})
      assert_receive {:slot_fully_warmed, 1}, 2000

      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, 1, "issue-2"})
      refute_receive {:slot_fully_warmed, 1}, 1000

      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_removed, 1, "issue-1"})
      refute_receive {:slot_warmth_dropped, 1}, 1000

      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_removed, 1, "issue-2"})
      assert_receive {:slot_warmth_dropped, 1}, 2000
    end

    test "attach_state_changed carries attach_count and visible_in through mark/clear cycles",
         %{pool: pool} do
      Phoenix.PubSub.subscribe(Aiur.PubSub, AttachPool.topic())

      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, 1, "issue-1"})
      assert_receive {:attach_state_changed, "issue-1", 1, nil}, 2000
      assert AttachPool.attach_count(pool, "issue-1") == 1

      AttachPool.mark_visible(pool, "issue-1", 1)
      assert_receive {:attach_state_changed, "issue-1", 1, 1}, 2000
      assert AttachPool.visible_count(pool) == 1

      AttachPool.clear_visible(pool, "issue-1")
      assert_receive {:attach_state_changed, "issue-1", 1, nil}, 2000
      assert AttachPool.visible_count(pool) == 0
    end
  end

  describe "attach/reclaim under churn (#372/#607/#608 TOCTOU class)" do
    test "free_slots_for/2 reclaim decision table" do
      assert AttachPool.free_slots_for([{1, "issue-1"}, {2, "issue-1"}, {3, nil}], [
               "issue-1",
               "issue-2"
             ]) == [2, 3]

      assert AttachPool.free_slots_for([{1, "stale"}, {2, "issue-1"}], ["issue-1"]) == [1]
      assert AttachPool.free_slots_for([], ["issue-1"]) == []
      assert AttachPool.free_slots_for([{1, nil}, {2, nil}], []) == [1, 2]
    end

    test "find_slot_for prefers the identifier's own visible slot (instant-open fast path)",
         %{pool: pool} do
      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, 1, "issue-1"})
      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, 2, "issue-1"})
      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_visible_changed, 2, "issue-1"})
      sync(pool)

      assert AttachPool.find_slot_for(pool, "issue-1") == {:ok, 2}

      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_visible_changed, 2, nil})
      sync(pool)

      assert AttachPool.find_slot_for(pool, "issue-1") == {:ok, 1}
    end

    test "find_slot_for honors :prefer and :exclude_slots", %{pool: pool} do
      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, 1, "issue-1"})
      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, 2, "issue-1"})
      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_visible_changed, 2, "issue-1"})
      sync(pool)

      assert AttachPool.find_slot_for(pool, "issue-1", prefer: 1) == {:ok, 1}
      assert AttachPool.find_slot_for(pool, "issue-1", exclude_slots: [1, 2]) == :miss
      assert AttachPool.find_slot_for(pool, "issue-1", exclude_slots: [2]) == {:ok, 1}
    end

    test "post-boot churn: removed identifier detaches, newcomer claims the freed slot, unpaired newcomer attaches nowhere",
         %{pool: pool} do
      Phoenix.PubSub.subscribe(Aiur.PubSub, AttachPool.topic())
      start_slots(self(), 2)

      AttachPool.seed(pool, ["issue-a", "issue-b"])
      assert_receive {:slot_call, :set_visible, 1, "issue-a"}, 2000
      assert_receive {:slot_call, :set_visible, 2, "issue-b"}, 2000

      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, 1, "issue-a"})
      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, 2, "issue-b"})
      sync(pool)

      AttachPool.seed(pool, ["issue-b", "issue-c", "issue-d"])
      assert_receive {:slot_call, :detach, 1, "issue-a"}, 2000
      assert_receive {:agent_inactive, "issue-a"}, 2000
      assert_receive {:slot_call, :set_visible, 1, "issue-c"}, 2000
      refute_receive {:slot_call, :set_visible, _, "issue-d"}, 1000
      refute_receive {:slot_call, :attach, _, _}, 1000
      assert AttachPool.find_slot_for(pool, "issue-d") == :miss
    end
  end

  describe "FD/attach fan-out census (#409 :emfile class)" do
    test "boot census: N=6 agents x M=3 slots => exactly M set_visible, zero attach",
         %{pool: pool} do
      ids = for i <- 1..6, do: "issue-#{i}"

      AttachPool.seed(pool, ids)
      sync(pool)
      start_slots(self(), 3)
      announce_ready([1, 2, 3])

      assert_receive {:slot_call, :set_visible, 1, "issue-1"}, 2000
      assert_receive {:slot_call, :set_visible, 2, "issue-2"}, 2000
      assert_receive {:slot_call, :set_visible, 3, "issue-3"}, 2000
      refute_receive {:slot_call, :attach, _, _}, 1000
      refute_receive {:slot_call, :set_visible, _, _}, 1000

      for id <- ["issue-4", "issue-5", "issue-6"] do
        assert AttachPool.find_slot_for(pool, id) == :miss
        assert AttachPool.attach_count(pool, id) == 0
      end
    end

    test "slot pool budget: target_count 0 boots zero slots and grow_slot refuses at max_slots" do
      unique = System.unique_integer([:positive, :monotonic])
      pubsub_name = Module.concat(__MODULE__, "PubSub#{unique}")
      policy_name = Module.concat(__MODULE__, "Policy#{unique}")

      start_supervised!({Phoenix.PubSub, name: pubsub_name}, id: {Phoenix.PubSub, pubsub_name})

      {:ok, policy} =
        SlotPolicy.start_link(name: policy_name, target_count: 0, max_slots: 0, pubsub: pubsub_name)

      assert SlotPolicy.target_count(policy) == 0
      assert SlotPolicy.highest_started(policy) == 0
      assert SlotPolicy.grow_slot(policy) == {:error, :at_capacity}
    end
  end

  describe "operator-message preservation through slot lifecycle (#332 class)" do
    test "detach never reaps the identifier's SessionWriter" do
      source = File.read!(@slot_source)

      block =
        extract!(
          source,
          ~r/def handle_call\(\{:detach, identifier\}, _from, state\) do.*?\n  end\n/s
        )

      refute block =~ "SessionWriterRegistry",
             """
             Detach must not touch SessionWriterRegistry. The detached agent's
             SessionWriter must stay alive so re-attach, and any queued operator
             message in its session, survives; reaping here recreates the #332
             lost-message class.
             """

      refute block =~ "reap_session_writer",
             """
             Detach must not reap a specific SessionWriter. Re-attach depends on
             the existing writer/session surviving slot churn; deleting it here
             drops queued operator messages from the #332 incident class.
             """

      assert block =~ "Events.attach_removed",
             """
             Detach still must broadcast attach removal so AttachPool and the UI
             leave the warm state correctly without killing the SessionWriter.
             """
    end

    test "set_visible same-identifier fast path returns the existing pane without respawn" do
      source = File.read!(@slot_source)

      assert source =~ ~r/state\.visible_identifier == identifier and is_binary\(state\.pane_id\)/,
             """
             PaneManager's instant open depends on this no-op fast path. A
             respawn here kills the pane a user may be typing an operator
             message into, and the /tui/select-session HTTP path must never be
             reintroduced because opencode kills the attach seconds after 200.
             """
    end

    test "deferred select reply vs fire-and-forget attach retry stay distinct contracts" do
      source = File.read!(@slot_source)

      select_block =
        extract!(
          source,
          ~r/defp drain_pending_select\(%\{pending_select: \{from, identifier\}\} = state\) do.*?\n  end\n/s
        )

      retry_block =
        extract!(source, ~r/defp retry_pending_attach\(id, acc\) do.*?\n  end\n/s)

      assert select_block =~ "GenServer.reply(from,",
             """
             pending_select holds a caller mid-GenServer.call across a serve
             rebuild; it must reply after :ready or the caller's open hangs.
             """

      refute retry_block =~ "GenServer.reply",
             """
             pending_attaches callers were already answered
             {:error, :identifier_unknown}. Unifying this with pending_select
             either double-replies or drops the deferred reply (giant-slot.md
             risk 5).
             """
    end
  end

  describe "rebuild/watchdog invariants (source-pinned)" do
    test "serve rebuild teardown order: reap writers -> stop serve -> kill pane -> delete token -> rebuild_now" do
      slot_source = File.read!(@slot_source)
      lifecycle_source = File.read!(@serve_lifecycle_source)

      # Teardown ordering lives in ServeLifecycle.teardown_generation (T-046 decomposition).
      block = extract!(lifecycle_source, ~r/def teardown_generation\(state\) do.*?\n  end\n/s)

      assert pos!(block, "reap_writers_for_base_url") <
               pos!(block, "GenServer.stop(state.server_pid"),
             """
             Rebuild must reap writers first so DELETE /session reaches a
             still-live serve (#372).
             """

      assert pos!(block, "GenServer.stop(state.server_pid") < pos!(block, "AttachPane.kill(state.pane_id"),
             """
             The old serve stops before its pane is killed; this preserves the
             documented rebuild lifecycle and keeps teardown deterministic.
             """

      assert pos!(block, "AttachPane.kill(state.pane_id") < pos!(block, "TokenRegistry.delete"),
             """
             The pane must be killed before clearing pane_id or identifier-miss
             rebuilds leak panes until the hidden window hits no space for new
             pane.
             """

      # :rebuild_now is sent from do_schedule_serve_rebuild in slot.ex AFTER teardown_generation.
      rebuild_block =
        extract!(slot_source, ~r/defp do_schedule_serve_rebuild\(state, pending, next_known\) do.*?\n  end\n/s)

      assert pos!(rebuild_block, "ServeLifecycle.teardown_generation") <
               pos!(rebuild_block, "send(self(), :rebuild_now)"),
             """
             Token delete before the rebuild self-message keeps the
             {slot_index, generation} overlap window intact.
             """
    end

    test "pane-death watchdog: threshold 3, reset on success, cancel-before-reschedule" do
      slot_source = File.read!(@slot_source)
      state_source = File.read!(@state_source)

      # @poll_death_threshold moved to State module (T-046 decomposition).
      assert state_source =~ ~r/@poll_death_threshold 3/

      # Successful poll resets poll_death_count to 0 via State.record_poll/2.
      assert state_source =~
               ~r/def record_poll\(state, :alive\), do: \{:alive, %\{state \| poll_death_count: 0\}\}/,
             """
             tmux display-message can return empty under transient load; a
             successful poll must reset the consecutive-failure debounce so one
             bad reading cannot tear down a live pane.
             """

      block = extract!(slot_source, ~r/defp schedule_poll\(%\{status: :active\} = state\) do.*?\n  end\n/s)

      assert pos!(block, "cancel_poll(state.poll_ref)") < pos!(block, "poll_ref: Process.send_after"),
             """
             schedule_poll must cancel before rescheduling. Stacked timers fire
             together, defeating the consecutive-failures debounce and
             false-killing a live pane.
             """
    end

    test "attach_many stays sequential (PR #83 SQLite contention)" do
      source = File.read!(@slot_source)

      block =
        extract!(
          source,
          ~r/def attach_many\(server, identifiers, timeout[^\n]*\) when is_list\(identifiers\) do.*?\n  end\n/s
        )

      assert block =~ "Enum.map",
             """
             attach_many must stay sequential so replay work against one serve
             does not reintroduce PR #83 SQLite write-lock contention.
             """

      refute block =~ ~r/Task\.(async|start|Supervisor)/,
             """
             Parallel attaches against one serve hit SQLite write-lock
             contention even after PR #83's transaction batching; replay
             timeouts wedge slots at the warming state.
             """
    end
  end
end

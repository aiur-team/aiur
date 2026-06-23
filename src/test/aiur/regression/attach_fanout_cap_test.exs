defmodule Aiur.Regression.AttachFanoutCapTest do
  @moduledoc """
  Regression for #409 — the `:emfile` structural fix.

  The crash was the superposition of N×M attach handles (every active
  agent attached to every slot), the 16× compile storm (fixed by
  prewarm), and the per-pane tmux poll. This test pins the attach-layer
  fix: the AttachPool fans out **one leadoff `set_visible` per slot**
  and does NOT background-attach every other active identifier into
  every slot — at EITHER of the two former fan-out sites:

    * `run_leadoff_task` (driven by `:slot_ready`) — the boot leadoff path
    * `do_seed`'s post-boot fill (a queued agent dispatched after slots
      are already full) — the late-arrival path

  Before the fix, seeding N agents across M slots produced `M` leadoff
  `set_visible` calls PLUS `M × (N-1)` background `attach` calls — the
  256-handle fan-out at N=16/M=16. After the fix the background fill is
  gone. Non-leadoff agents fall through to the on-demand cold-open path
  (`AttachPool.consume` → `:miss` → `PaneManager.open_with_placeholder`).
  """

  use ExUnit.Case, async: false

  alias Aiur.Opencode.{AttachPool, Slot, SlotRegistry}

  # A stand-in Slot worker: registers itself in SlotRegistry so the
  # AttachPool's leadoff/fill tasks find a live pid, forwards every
  # set_visible / attach call to the test process so we can count them,
  # and tracks its visible identifier so do_seed's free-slot detection
  # (which reads `Slot.snapshot/1`) sees a slot as "claimed" once its
  # leadoff has painted.
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

    def handle_call(:snapshot, _from, state) do
      {:reply, %{visible_identifier: state.visible}, state}
    end
  end

  setup do
    {:ok, pool} =
      AttachPool.start_link(name: :"AttachPool_#{System.unique_integer([:positive])}")

    {:ok, pool: pool}
  end

  test "leadoff fan-out: M set_visible, 0 background attach", %{pool: pool} do
    test = self()
    n = 4
    m = 2

    # Seed N=4 active agents while NO slots are registered yet, so
    # do_seed's running-slot fan-out is a no-op and we isolate the
    # leadoff path driven by :slot_ready below.
    ids = for i <- 1..n, do: "issue-#{i}"
    AttachPool.seed(pool, ids)
    Process.sleep(20)

    start_slots(test, m)
    announce_ready(m)

    calls = drain_slot_calls()

    assert count(calls, :set_visible) == m,
           "expected exactly one leadoff set_visible per slot (#{m}), got: #{inspect(calls)}"

    assert filter(calls, :attach) == [],
           """
           expected ZERO background attach calls — the leadoff-only fan-out
           must not attach every other active identifier into every slot
           (that was the M×(N-1) handle blow-up behind :emfile). Got:
           #{inspect(filter(calls, :attach))}
           """

    # The non-leadoff agents are attached nowhere, so opening them must
    # route to the on-demand cold-open path (consume → :miss), not a
    # warm slot. (issue-1/issue-2 are the leadoffs for slots 1/2.)
    assert AttachPool.consume("issue-3") == :miss
    assert AttachPool.consume("issue-4") == :miss
  end

  test "post-boot addition with slots full: 0 background attach", %{pool: pool} do
    test = self()
    m = 2

    # Bring up M slots, then seed M agents so each claims a leadoff slot.
    start_slots(test, m)
    AttachPool.seed(pool, ["issue-1", "issue-2"])
    announce_ready(m)

    # Wait until both leadoffs have painted — now both slots report a
    # visible identifier, so the next seed sees no free slot.
    _ = drain_slot_calls()

    # A queued agent gets dispatched after the slots are full. Before the
    # fix this fired `Slot.attach` into EVERY running slot (the post-boot
    # M×N contributor); after the fix it attaches nowhere.
    AttachPool.seed(pool, ["issue-1", "issue-2", "issue-3"])

    calls = drain_slot_calls()

    assert filter(calls, :attach) == [],
           """
           a post-boot addition with no free slot must NOT background-attach
           into the running slots. Got: #{inspect(filter(calls, :attach))}
           """

    assert AttachPool.consume("issue-3") == :miss
  end

  defp start_slots(test, m) do
    for index <- 1..m do
      {:ok, _} = start_supervised({RecordingSlot, [index: index, test: test]}, id: {:slot, index})
    end
  end

  defp announce_ready(m) do
    for index <- 1..m do
      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_ready, index})
    end
  end

  defp count(calls, kind), do: calls |> filter(kind) |> length()
  defp filter(calls, kind), do: Enum.filter(calls, fn {k, _idx, _id} -> k == kind end)

  # Collect {:slot_call, ...} messages until the stream goes quiet.
  defp drain_slot_calls(acc \\ []) do
    receive do
      {:slot_call, kind, index, id} -> drain_slot_calls([{kind, index, id} | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end
end

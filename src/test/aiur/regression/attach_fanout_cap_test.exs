defmodule Aiur.Regression.AttachFanoutCapTest do
  @moduledoc """
  Regression for #409 — the `:emfile` structural fix.

  The crash was the superposition of N×M attach handles (every active
  agent attached to every slot), the 16× compile storm (fixed by
  prewarm), and the per-pane tmux poll. This test pins the attach-layer
  fix: the AttachPool fans out **one leadoff `set_visible` per slot**
  and does NOT background-attach every other active identifier into
  every slot.

  Before the fix, seeding N agents across M slots produced
  `M` leadoff `set_visible` calls PLUS `M × (N-1)` background
  `attach` calls — the 256 SessionWriter/session/SQLite-row fan-out at
  N=16/M=16. After the fix the background fill is gone: `M` set_visible,
  `0` attach. Non-leadoff agents fall through to the on-demand cold-open
  path (`AttachPool.consume` → `:miss` → `PaneManager.open_with_placeholder`).
  """

  use ExUnit.Case, async: false

  alias Aiur.Opencode.{AttachPool, Slot, SlotRegistry}

  # A stand-in Slot worker: registers itself in SlotRegistry so the
  # AttachPool's leadoff/fill tasks find a live pid, and forwards every
  # set_visible / attach call to the test process so we can count them.
  defmodule RecordingSlot do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      index = Keyword.fetch!(opts, :index)
      test = Keyword.fetch!(opts, :test)
      :ok = SlotRegistry.register_self(index)
      {:ok, %{index: index, test: test}}
    end

    @impl true
    def handle_call({:set_visible, identifier}, _from, state) do
      send(state.test, {:slot_call, :set_visible, state.index, identifier})
      {:reply, {:ok, "%#{state.index}"}, state}
    end

    def handle_call({:attach, identifier}, _from, state) do
      send(state.test, {:slot_call, :attach, state.index, identifier})
      {:reply, {:ok, :attached}, state}
    end

    def handle_call(:snapshot, _from, state) do
      {:reply, %{visible_identifier: nil}, state}
    end
  end

  test "fan-out is leadoff-only: M set_visible, 0 background attach" do
    {:ok, pool} =
      AttachPool.start_link(name: :"AttachPool_#{System.unique_integer([:positive])}")

    test = self()

    # Seed N=4 active agents while NO slots are registered yet, so
    # do_seed's running-slot fan-out is a no-op and we isolate the
    # leadoff path driven by :slot_ready below.
    n = 4
    m = 2
    ids = for i <- 1..n, do: "issue-#{i}"
    AttachPool.seed(pool, ids)
    Process.sleep(20)

    # Bring up M slots and announce each ready — this is the kickoff
    # fan-out path that previously also background-attached every other
    # active identifier.
    for index <- 1..m do
      {:ok, _} = start_supervised({RecordingSlot, [index: index, test: test]}, id: {:slot, index})
    end

    for index <- 1..m do
      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_ready, index})
    end

    calls = drain_slot_calls([])

    set_visible_calls = Enum.filter(calls, fn {kind, _idx, _id} -> kind == :set_visible end)
    attach_calls = Enum.filter(calls, fn {kind, _idx, _id} -> kind == :attach end)

    assert length(set_visible_calls) == m,
           "expected exactly one leadoff set_visible per slot (#{m}), got: #{inspect(set_visible_calls)}"

    assert attach_calls == [],
           """
           expected ZERO background attach calls — the leadoff-only fan-out
           must not attach every other active identifier into every slot
           (that was the M×(N-1) handle blow-up behind :emfile). Got:
           #{inspect(attach_calls)}
           """
  end

  # Collect {:slot_call, ...} messages until the stream goes quiet.
  defp drain_slot_calls(acc) do
    receive do
      {:slot_call, kind, index, id} -> drain_slot_calls([{kind, index, id} | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end
end

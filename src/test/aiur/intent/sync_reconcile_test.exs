defmodule Aiur.Intent.SyncReconcileTest do
  use ExUnit.Case, async: true

  import Aiur.IntentFixtures

  alias Aiur.Intent.{Store, Sync}

  @n 5_000_000

  setup do
    parent = self()
    {:ok, clock} = Agent.start_link(fn -> @n end)
    {:ok, rows} = Agent.start_link(fn -> [] end)
    {:ok, store} = Store.start_link(dir: tmp_dir("intent-rec"), name: nil)
    table = String.to_atom("intent_rec_#{System.unique_integer([:positive])}")

    {:ok, sync} =
      Sync.start_link(
        name: nil,
        table: table,
        store: store,
        interval_ms: 3_600_000,
        own_gateway: "LOCAL",
        now_fun: fn -> Agent.get(clock, & &1) end,
        emit_fun: fn name, opts -> send(parent, {:emit, name, opts}) end,
        observe_fun: &send(parent, {:observe, &1}),
        broadcast_fun: &send(parent, {:broadcast, &1}),
        publish_fun: fn _ -> {:ok, []} end,
        pull_fun: fn cursor, _limit, _opts -> {:ok, Agent.get(rows, &Enum.filter(&1, fn r -> r.seq > cursor end))} end
      )

    %{clock: clock, rows: rows, store: store, table: table, sync: sync}
  end

  defp remote(id, wall, v, o \\ %{}), do: change(Map.merge(%{change_id: id, hlc_wall_ms: wall, value_json: v, origin_gateway: "REMOTE"}, o))
  defp skewed(id \\ "far"), do: remote(id, @n + 61_000, "f")
  defp tick(c), do: :ok = Sync.sync_once(c.sync)

  test "apply_remote of a far-future change is held, alerts once, and later delivery by pull stays silent", c do
    ch = skewed()
    assert {:ok, :held} = Sync.apply_remote(ch, store: c.store, table: c.table)
    assert_receive {:emit, "system.intent.clock_skew", opts}, 500
    assert opts[:message] =~ "far"
    assert {:ok, :duplicate} = Sync.apply_remote(ch, store: c.store, table: c.table)

    Agent.update(c.rows, &(&1 ++ [%{ch | seq: 1}]))
    tick(c)
    tick(c)
    refute_receive {:emit, _, _}, 50
    refute_receive {:observe, _}, 0
    refute_receive {:broadcast, _}, 0
  end

  test "three ticks alert exactly once; the change applies, merges into the HLC and notifies after the clock passes", c do
    Agent.update(c.rows, &(&1 ++ [%{skewed() | seq: 1}]))
    for _ <- 1..3, do: tick(c)
    assert_receive {:emit, "system.intent.clock_skew", _}, 500
    refute_receive {:emit, _, _}, 50
    refute_receive {:observe, _}, 0

    Agent.update(c.clock, &(&1 + 2_000))
    tick(c)
    assert_receive {:observe, {wall, 0}} when wall == @n + 61_000, 500
    assert_receive {:broadcast, {:intent_register_changed, {"ticket", "aiur-team/aiur#7626", "order_key"}, "f"}}, 500
    refute_receive {:emit, _, _}, 50
  end

  test "notify: an unchanged refold is silent; a pause flip broadcasts exactly once", c do
    pause = remote("p", @n - 5, true, %{slot: "executor", entity_kind: "fleet", entity_key: "fleet", field: "pause"})
    assert {:ok, :applied} = Sync.apply_remote(pause, store: c.store, table: c.table)
    assert_receive {:broadcast, {:intent_register_changed, {"fleet", "fleet", "pause"}, true}}, 500
    tick(c)
    tick(c)
    refute_receive {:broadcast, _}, 50
  end

  test "applying remote changes never touches the outbox", c do
    one = remote("a", @n - 20, "1")
    two = remote("b", @n - 10, "2", %{entity_key: "aiur-team/aiur#2"})
    for ch <- [one, two, two], do: Sync.apply_remote(ch, store: c.store, table: c.table)
    assert Store.outbox(c.store) == []
    assert length(Store.changes(c.store)) == 2
  end
end

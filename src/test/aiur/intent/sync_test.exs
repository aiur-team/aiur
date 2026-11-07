defmodule Aiur.Intent.SyncTest do
  use ExUnit.Case, async: true

  import Aiur.IntentFixtures

  alias Aiur.Intent.{Store, Sync}

  # In-memory stand-in for aiur_intent_changes: ON CONFLICT (change_id) DO NOTHING plus a seq.
  defmodule Fake do
    use Agent
    def start_link(_), do: Agent.start_link(fn -> %{up?: true, rows: [], calls: 0} end)
    def up(a, up?), do: Agent.update(a, &%{&1 | up?: up?})
    def rows(a), do: Agent.get(a, & &1.rows)
    def put(a, c), do: Agent.update(a, &%{&1 | rows: &1.rows ++ [c]})

    def publish(a, changes) do
      Agent.get_and_update(a, fn
        %{up?: false} = s ->
          {{:error, {:store_unavailable, :down}}, s}

        s ->
          known = MapSet.new(s.rows, & &1.change_id)

          new =
            changes
            |> Enum.reject(&MapSet.member?(known, &1.change_id))
            |> Enum.uniq_by(& &1.change_id)
            |> Enum.with_index(length(s.rows) + 1)
            |> Enum.map(fn {c, i} -> %{c | seq: i} end)

          {{:ok, Enum.map(changes, & &1.change_id)}, %{s | rows: s.rows ++ new}}
      end)
    end

    def since(a, cursor, limit) do
      Agent.get(a, fn
        %{up?: false} -> {:error, {:store_unavailable, :down}}
        s -> {:ok, s.rows |> Enum.filter(&(&1.seq > cursor)) |> Enum.take(limit)}
      end)
    end
  end

  setup do
    {:ok, fake} = Fake.start_link([])
    {:ok, store} = Store.start_link(dir: tmp_dir("intent-sync"), name: nil)

    {:ok, sync} =
      Sync.start_link(
        name: nil,
        store: store,
        interval_ms: 3_600_000,
        publish_fun: &Fake.publish(fake, &1),
        pull_fun: &Fake.since(fake, &1, &2)
      )

    {:ok, fake: fake, store: store, sync: sync}
  end

  test "a change written while the store is down reaches it exactly once after reconnect", c do
    Fake.up(c.fake, false)
    ch = change()
    :ok = Store.append_local(c.store, ch)
    assert {:error, {:store_unavailable, _}} = Sync.sync_once(c.sync)
    assert Store.outbox(c.store) == [ch]
    assert Fake.rows(c.fake) == []

    Fake.up(c.fake, true)
    assert :ok = Sync.sync_once(c.sync)
    assert Store.outbox(c.store) == []
    assert [%{change_id: id}] = Fake.rows(c.fake)
    assert id == ch.change_id
    assert Sync.status(c.sync).last_error == nil
  end

  test "pull appends remote rows in pages, advances the cursor and never touches the outbox", c do
    for i <- 1..3, do: Fake.put(c.fake, %{change(%{hlc_counter: i}) | seq: i})
    assert :ok = Sync.sync_once(c.sync)
    assert length(Store.changes(c.store)) == 3
    assert Store.pull_cursor(c.store) == 3
    assert Store.outbox(c.store) == []
    assert Sync.status(c.sync).needs_pull == false
  end

  test "an invalid pulled row (daemon pause) is dropped and counted", c do
    bad = %{change(%{entity_kind: "gateway", entity_key: "g", field: "pause", slot: "default"}) | seq: 1}
    Fake.put(c.fake, bad)
    assert :ok = Sync.sync_once(c.sync)
    assert Store.changes(c.store) == []
    assert Sync.status(c.sync).skipped_invalid == 1
    assert Store.pull_cursor(c.store) == 1
  end

  test "failed pull leaves needs_pull true; success clears it", c do
    assert Sync.status(c.sync).needs_pull
    Fake.up(c.fake, false)
    assert {:error, _} = Sync.pull(server: c.sync)
    assert Sync.status(c.sync).needs_pull
    Fake.up(c.fake, true)
    assert :ok = Sync.pull(server: c.sync)
    refute Sync.status(c.sync).needs_pull
  end

  test "pull is bounded when the store hangs and leaves the cache untouched" do
    {:ok, store} = Store.start_link(dir: tmp_dir("intent-sync-hang"), name: nil)
    {:ok, sync} = Sync.start_link(name: nil, store: store, interval_ms: 3_600_000, pull_fun: fn _, _ -> Process.sleep(5_000) end)
    {t, result} = :timer.tc(fn -> Sync.pull(server: sync, timeout_ms: 50) end)
    assert result == {:error, :timeout}
    assert t < 1_000_000
    assert Store.changes(store) == []
    assert Store.pull_cursor(store) == 0
    assert Sync.status(sync).needs_pull
  end

  test "apply_remote validates, dedups, and never queues for publishing", c do
    ch = change()
    assert {:ok, :applied} = Sync.apply_remote(ch, store: c.store)
    assert {:ok, :duplicate} = Sync.apply_remote(ch, store: c.store)
    assert Store.outbox(c.store) == []
    assert Store.pull_cursor(c.store) == 0

    bad = change(%{entity_kind: "gateway", entity_key: "g", field: "pause", slot: "default"})
    assert {:error, :daemon_pause_rejected} = Sync.apply_remote(bad, store: c.store)
    assert length(Store.changes(c.store)) == 1

    Fake.put(c.fake, %{ch | seq: 9})
    Sync.sync_once(c.sync)
    assert length(Store.changes(c.store)) == 1
    assert Store.pull_cursor(c.store) == 9
  end

  test "pull without a running Sync is disabled" do
    assert Sync.pull(server: :no_such_sync) == {:error, :disabled}
  end
end

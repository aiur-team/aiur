defmodule Aiur.Intent.SyncTest do
  use ExUnit.Case, async: true

  import Aiur.IntentFixtures

  alias Aiur.Intent.{Store, Sync}

  # In-memory stand-in for aiur_intent_changes. Its dedup models ON CONFLICT; the real SQL is
  # proven by postgres_test.exs, which CI runs against PostgreSQL.
  defmodule Fake do
    use Agent
    def start_link(_), do: Agent.start_link(fn -> %{up?: true, rows: [], recent: [], calls: []} end)
    def up(a, up?), do: Agent.update(a, &%{&1 | up?: up?})
    def rows(a), do: Agent.get(a, & &1.rows)
    def calls(a), do: Agent.get(a, &Enum.reverse(&1.calls))
    def put(a, c, recent? \\ false), do: Agent.update(a, &%{&1 | rows: &1.rows ++ [c], recent: if(recent?, do: [c.change_id | &1.recent], else: &1.recent)})

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

    def since(a, cursor, limit, opts) do
      Agent.get_and_update(a, fn
        %{up?: false} = s ->
          {{:error, {:store_unavailable, :down}}, s}

        s ->
          late = if opts[:overlap], do: Enum.filter(s.rows, &(&1.seq <= cursor and &1.change_id in s.recent)), else: []
          page = s.rows |> Enum.filter(&(&1.seq > cursor)) |> Enum.take(limit)
          {{:ok, late ++ page}, %{s | calls: [{cursor, opts[:overlap]} | s.calls]}}
      end)
    end
  end

  defp start_sync(fake, store, extra \\ []) do
    table = String.to_atom("intent_sync_#{System.unique_integer([:positive])}")

    {:ok, sync} =
      Sync.start_link(
        extra ++
          [
            name: nil,
            table: table,
            store: store,
            interval_ms: 3_600_000,
            publish_fun: &Fake.publish(fake, &1),
            pull_fun: &Fake.since(fake, &1, &2, &3)
          ]
      )

    {sync, table}
  end

  setup do
    {:ok, fake} = Fake.start_link([])
    dir = tmp_dir("intent-sync")
    {:ok, store} = Store.start_link(dir: dir, name: nil)
    {sync, table} = start_sync(fake, store)
    {:ok, fake: fake, store: store, sync: sync, table: table, dir: dir}
  end

  defp restart_store(c) do
    GenServer.stop(c.store)
    {:ok, store} = Store.start_link(dir: c.dir, name: nil)
    store
  end

  test "a change written while the store is down survives a restart and reaches the store exactly once", c do
    Fake.up(c.fake, false)
    ch = change()
    :ok = Store.append_local(c.store, ch)
    assert {:error, {:store_unavailable, _}} = Sync.sync_once(c.sync)
    assert Fake.rows(c.fake) == []

    # the gateway restarts while the store is still down: only the outbox file can carry the change
    store = restart_store(c)
    assert Store.outbox(store) == [ch]

    Fake.up(c.fake, true)
    {sync, _} = start_sync(c.fake, store)
    assert :ok = Sync.sync_once(sync)
    assert Store.outbox(store) == []
    assert [%{change_id: id}] = Fake.rows(c.fake)
    assert id == ch.change_id
  end

  test "a crash after the insert but before the ack leaves one row and an empty outbox", c do
    ch = change()
    :ok = Store.append_local(c.store, ch)
    assert {:ok, [_]} = Fake.publish(c.fake, [ch])

    store = restart_store(c)
    assert Store.outbox(store) == [ch]
    {sync, _} = start_sync(c.fake, store)
    assert :ok = Sync.sync_once(sync)
    assert [_] = Fake.rows(c.fake)
    assert Store.outbox(store) == []
  end

  test "pull appends remote rows, advances the cursor and never touches the outbox", c do
    for i <- 1..3, do: Fake.put(c.fake, %{change(%{hlc_counter: i}) | seq: i})
    assert :ok = Sync.sync_once(c.sync)
    assert length(Store.changes(c.store)) == 3
    assert Store.pull_cursor(c.store) == 3
    assert Store.outbox(c.store) == []
    assert Sync.status(c.sync).needs_pull == false
  end

  test "1200 rows arrive in three pages, with the overlap fetched only on the first", c do
    for i <- 1..1200, do: Fake.put(c.fake, %{change(%{hlc_counter: i}) | seq: i})
    assert :ok = Sync.sync_once(c.sync)
    assert Fake.calls(c.fake) == [{0, true}, {500, false}, {1000, false}]
    assert length(Store.changes(c.store)) == 1200
    assert Store.pull_cursor(c.store) == 1200
  end

  test "a late-committing lower seq under the cursor is picked up by the overlap", c do
    {:ok, _} = Store.append_remote(c.store, [%{change() | seq: 42}], cursor: 42)
    late = %{change(%{hlc_counter: 41}) | seq: 41}
    Fake.put(c.fake, late, true)
    assert :ok = Sync.sync_once(c.sync)
    assert late.change_id in Enum.map(Store.changes(c.store), & &1.change_id)
    assert Store.pull_cursor(c.store) == 42
  end

  test "an invalid pulled row (daemon pause) is dropped and counted", c do
    bad = %{change(%{entity_kind: "gateway", entity_key: "g", field: "pause", slot: "default"}) | seq: 1}
    Fake.put(c.fake, bad)
    assert :ok = Sync.sync_once(c.sync)
    assert Store.changes(c.store) == []
    assert Sync.status(c.sync).skipped_invalid == 1
    assert Store.pull_cursor(c.store) == 1
  end

  test "needs_pull stays true through failures and clears only on a successful pull", c do
    assert Sync.status(c.sync).needs_pull
    Fake.up(c.fake, false)
    assert {:error, _} = Sync.pull(server: c.sync)
    assert Sync.status(c.sync).needs_pull
    Fake.up(c.fake, true)
    assert :ok = Sync.pull(server: c.sync)
    refute Sync.status(c.sync).needs_pull
  end

  test "a failure on page two keeps needs_pull true with the cursor at page one", c do
    for i <- 1..600, do: Fake.put(c.fake, %{change(%{hlc_counter: i}) | seq: i})
    calls = :counters.new(1, [])

    {sync, _} =
      start_sync(c.fake, c.store,
        pull_fun: fn cursor, limit, opts ->
          :counters.add(calls, 1, 1)
          if :counters.get(calls, 1) == 2, do: {:error, {:store_unavailable, :down}}, else: Fake.since(c.fake, cursor, limit, opts)
        end
      )

    assert {:error, _} = Sync.pull(server: sync)
    assert Store.pull_cursor(c.store) == 500
    assert Sync.status(sync).needs_pull
  end

  test "pull is bounded when the store hangs and leaves the cache untouched" do
    {:ok, store} = Store.start_link(dir: tmp_dir("intent-sync-hang"), name: nil)
    {:ok, fake} = Fake.start_link([])
    {sync, _} = start_sync(fake, store, pull_fun: fn _, _, _ -> Process.sleep(5_000) end)
    {t, result} = :timer.tc(fn -> Sync.pull(server: sync, timeout_ms: 50) end)
    assert result == {:error, :timeout}
    assert t < 1_000_000
    assert Store.changes(store) == []
    assert Store.pull_cursor(store) == 0
    assert Sync.status(sync).needs_pull
  end

  test "ensure_fresh is :ok without any pull when fresh, pulls when stale, backs off after a failure", c do
    assert :ok = Sync.ensure_fresh(1_000, server: c.sync, table: c.table)
    assert length(Fake.calls(c.fake)) == 1
    refute Sync.status(c.sync).needs_pull

    assert :ok = Sync.ensure_fresh(1_000, server: c.sync, table: c.table)
    assert length(Fake.calls(c.fake)) == 1

    Fake.up(c.fake, false)
    assert {:error, {:store_unavailable, _}} = Sync.pull(server: c.sync)
    Fake.up(c.fake, true)
    before = length(Fake.calls(c.fake))
    assert {:error, :recently_failed} = Sync.ensure_fresh(1_000, server: c.sync, table: c.table)
    assert length(Fake.calls(c.fake)) == before
  end

  test "ensure_fresh is :ok when Sync is not running" do
    assert :ok = Sync.ensure_fresh(1_000, table: :no_such_intent_table)
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

  test "the remote-applied hook gets exactly the new changes, never a duplicate" do
    parent = self()
    {:ok, fake} = Fake.start_link([])
    {:ok, store} = Store.start_link(dir: tmp_dir("intent-hook"), name: nil)
    {sync, _} = start_sync(fake, store, on_remote_applied: &send(parent, {:pulled, &1}))

    pulled = %{change(%{hlc_counter: 1}) | seq: 1}
    Fake.put(fake, pulled)
    :ok = Sync.sync_once(sync)
    assert_receive {:pulled, [got]}, 1_000
    assert got.change_id == pulled.change_id

    # the same row arriving again (overlap, or a second pull) is a duplicate: no hook call
    Fake.put(fake, %{pulled | seq: 1}, true)
    :ok = Sync.sync_once(sync)
    refute_receive {:pulled, _}, 50

    direct = change(%{hlc_counter: 7})
    hook = &send(parent, {:direct, &1})
    assert {:ok, :applied} = Sync.apply_remote(direct, store: store, on_remote_applied: hook)
    assert_receive {:direct, [^direct]}, 1_000
    assert {:ok, :duplicate} = Sync.apply_remote(direct, store: store, on_remote_applied: hook)
    refute_receive {:direct, _}, 50
  end

  test "apply_remote without the opt fires Sync's configured hook" do
    parent = self()
    {:ok, fake} = Fake.start_link([])
    {:ok, store} = Store.start_link(dir: tmp_dir("intent-hook-default"), name: nil)
    {_sync, table} = start_sync(fake, store, on_remote_applied: &send(parent, {:configured, &1}))

    direct = change(%{hlc_counter: 9})
    assert {:ok, :applied} = Sync.apply_remote(direct, store: store, table: table)
    assert_receive {:configured, [^direct]}, 1_000
    assert {:ok, :duplicate} = Sync.apply_remote(direct, store: store, table: table)
    refute_receive {:configured, _}, 50
  end

  test "pull without a running Sync is disabled" do
    assert Sync.pull(server: :no_such_sync) == {:error, :disabled}
  end
end

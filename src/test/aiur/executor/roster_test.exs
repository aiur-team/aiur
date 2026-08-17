defmodule Aiur.Executor.RosterTest do
  use Aiur.TestSupport

  alias Aiur.Executor.{Claims, Roster}
  alias Aiur.JsonStore

  @stall_after_ms 60_000

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-executor-roster-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{path: Path.join(root, "claims.json")}
  end

  test "a stalled owner is reported stalled, not active", %{path: path} do
    now = DateTime.utc_now()
    {:ok, _entry} = Claims.claim("agent-a", path: path, now: now)

    # It consumed once, long ago, and has renewed ever since. Presence alone
    # would call this healthy: the lease is perfect while the work has stopped.
    {:ok, _acked} = Claims.record_acknowledgement("agent-a", 5, path: path, now: now)

    later = DateTime.add(now, 10 * @stall_after_ms, :millisecond)
    {:ok, _renewed} = Claims.renew("agent-a", path: path, now: later)

    # First observation establishes the baseline: 7 records waiting.
    _first =
      Roster.build(path: path, now: later, cursor: 5, pending_count: 7, stall_after_ms: @stall_after_ms)

    # The queue grew while acknowledgements stayed frozen.
    later_still = DateTime.add(later, 1_000, :millisecond)
    {:ok, _renewed} = Claims.renew("agent-a", path: path, now: later_still)

    # The cursor also advances here — the inbox evicted unread records at its
    # bound — and that must not rescue the stalled owner.
    roster =
      Roster.build(path: path, now: later_still, cursor: 31, pending_count: 42, stall_after_ms: @stall_after_ms)

    entry = hd(roster.executors)

    assert entry.state == :stalled
    refute entry.state == :active
    assert entry.pending_count == 42
    assert entry.cursor_moved == true
    assert is_binary(entry.last_renewed_at)
    assert is_binary(entry.last_acknowledged_at)
    assert Roster.describe_line(entry) =~ "state=stalled"
  end

  test "active requires this consumer's own acknowledgement, not a cursor that moved" do
    # The shared cursor is not per-consumer evidence: it also advances when a
    # different consumer acknowledges, and when the inbox evicts unread records
    # at its bound. Either would promote a wedged consumer on someone else's
    # work, which is the exact failure this roster exists to prevent.
    now = DateTime.utc_now()
    path = Path.join(System.tmp_dir!(), "aiur-roster-evidence-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm_rf!(path) end)

    {:ok, _owner} = Claims.claim("agent-a", path: path, now: now)
    {:ok, _observer} = Claims.observe("agent-b", path: path, now: now)

    stale = DateTime.add(now, -10 * @stall_after_ms, :millisecond)
    {:ok, _acked} = Claims.record_acknowledgement("agent-a", 5, path: path, now: stale)
    {:ok, _renewed} = Claims.renew("agent-a", path: path, now: now)

    _baseline = Roster.build(path: path, now: now, cursor: 5, pending_count: 3, stall_after_ms: @stall_after_ms)

    # The cursor moves, but neither consumer acknowledged anything.
    roster = Roster.build(path: path, now: now, cursor: 9, pending_count: 3, stall_after_ms: @stall_after_ms)

    for entry <- roster.executors do
      assert entry.cursor_moved == true
      refute entry.state == :active
    end

    # Now the owner really acknowledges, and only the owner turns active.
    {:ok, _acked} = Claims.record_acknowledgement("agent-a", 9, path: path, now: now)
    roster = Roster.build(path: path, now: now, cursor: 9, pending_count: 3, stall_after_ms: @stall_after_ms)

    assert Enum.find(roster.executors, &(&1.id == "agent-a")).state == :active
    refute Enum.find(roster.executors, &(&1.id == "agent-b")).state == :active
  end

  test "removing the evidence degrades the state to unknown, never to active", %{path: path} do
    now = DateTime.utc_now()
    {:ok, _entry} = Claims.claim("agent-a", path: path, now: now)
    {:ok, _acked} = Claims.record_acknowledgement("agent-a", 5, path: path, now: now)

    _baseline = Roster.build(path: path, now: now, cursor: 9, pending_count: 3, stall_after_ms: @stall_after_ms)

    assert hd(Roster.build(path: path, now: now, cursor: 9, pending_count: 3, stall_after_ms: @stall_after_ms).executors).state == :active

    strip_evidence(path, "agent-a", ["last_acknowledged_at", "observation", "claimed_at"])

    roster = Roster.build(path: path, now: now, cursor: 9, pending_count: 3, stall_after_ms: @stall_after_ms, record?: false)
    entry = hd(roster.executors)

    assert entry.state == :unknown
    refute entry.state == :active
  end

  test "a dead owner is reported expired after its lease lapses, with no operator action", %{path: path} do
    now = DateTime.utc_now()
    {:ok, _entry} = Claims.claim("agent-a", path: path, now: now)

    later = DateTime.add(now, 10 * Claims.lease_ttl_ms(), :millisecond)
    roster = Roster.build(path: path, now: later, cursor: 0, pending_count: 4, stall_after_ms: @stall_after_ms)

    assert hd(roster.executors).state == :expired
  end

  test "two healthy executors are both listed and neither is flagged", %{path: path} do
    now = DateTime.utc_now()
    {:ok, _owner} = Claims.claim("agent-a", path: path, now: now)
    {:ok, _observer} = Claims.observe("agent-b", path: path, now: now)
    {:ok, _acked} = Claims.record_acknowledgement("agent-a", 5, path: path, now: now)

    roster = Roster.build(path: path, now: now, cursor: 5, pending_count: 0, stall_after_ms: @stall_after_ms)

    assert length(roster.executors) == 2
    assert Enum.sort(Enum.map(roster.executors, & &1.role)) == ["observer", "owner"]

    # Neither is flagged: the owner is consuming, and an observer with an empty
    # queue is legitimately idle rather than suspect.
    assert Enum.find(roster.executors, &(&1.id == "agent-a")).state == :active
    assert Enum.find(roster.executors, &(&1.id == "agent-b")).state == :idle
    refute Enum.any?(roster.executors, &(&1.state in [:stalled, :expired, :unknown]))
  end

  test "a non-owner cannot write acknowledgement evidence", %{path: path} do
    now = DateTime.utc_now()
    {:ok, _owner} = Claims.claim("agent-a", path: path, now: now)
    {:ok, _observer} = Claims.observe("agent-b", path: path, now: now)

    assert {:error, {:not_owner, owner}} = Claims.record_acknowledgement("agent-b", 5, path: path, now: now)
    assert owner["id"] == "agent-a"
  end

  test "an idle owner with an empty queue is idle, not stalled", %{path: path} do
    now = DateTime.utc_now()
    {:ok, _entry} = Claims.claim("agent-a", path: path, now: now)
    later = DateTime.add(now, 10 * @stall_after_ms, :millisecond)
    {:ok, _renewed} = Claims.renew("agent-a", path: path, now: later)

    roster = Roster.build(path: path, now: later, cursor: 5, pending_count: 0, stall_after_ms: @stall_after_ms)
    assert hd(roster.executors).state == :idle
  end

  defp strip_evidence(path, id, keys) do
    {:ok, state} = JsonStore.read(path, %{})
    entry = Enum.reduce(keys, state["consumers"][id], &Map.delete(&2, &1))
    JsonStore.write!(path, put_in(state, ["consumers", id], entry))
  end
end

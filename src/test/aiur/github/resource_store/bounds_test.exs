defmodule Aiur.GitHub.ResourceStore.BoundsTest do
  use Aiur.TestSupport
  use Aiur.ResourceStoreTestSupport

  alias Aiur.GitHub.ResourceStore

  describe "an unlisted resource type fails loudly" do
    # The trap: `@resource_types` is a closed set that `decode_key/1` resolves
    # against, so an unlisted type reads and writes perfectly until the next
    # restart and then vanishes with no error. Refusing at the key turns a body
    # that silently disappears into a caller that degrades visibly.
    test "key/4 refuses an unknown type and says so" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ResourceStore.key(:not_a_real_type, "owner", "repo", 1) == nil
        end)

      assert log =~ "refused unknown resource type"
      assert log =~ "not_a_real_type"
    end

    test "every listed type builds a key" do
      for type <- ResourceStore.resource_types() do
        assert ResourceStore.key(type, "owner", "repo", 1) != nil
      end
    end

    # A key built by hand bypasses `key/4`. The checkpoint is then the only place
    # it can be lost, so it is the place that has to name it.
    test "a key the checkpoint cannot render is named in the log", %{path: path} do
      restart_store!(path)
      ResourceStore.put_etag({:not_a_real_type, "owner", "repo", "1"}, ~s("x"))

      log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = ResourceStore.flush() end)

      assert log =~ "cannot checkpoint key"
      assert log =~ "not_a_real_type"
    end
  end

  # Every bound in this module was free to move: the size cap could be raised to
  # 290 KiB, the entry ceiling changed to anything, and the sweep cadence to any
  # interval, with the whole suite still green. A bound nothing pins is not a
  # bound, so each of these brackets its constant rather than restating it.
  describe "the bounds the store is built on" do
    # `{"b":"…"}` is the payload plus eight bytes of JSON framing, so these two
    # bodies encode to exactly the cap and exactly one byte past it.
    test "a body encoding to exactly the size cap is stored" do
      key = ResourceStore.key(:issue, "owner", "repo", 6001)
      data = %{"b" => String.duplicate("x", 256 * 1024 - 8)}

      assert byte_size(Jason.encode!(data)) == 256 * 1024

      ResourceStore.put_resource(key, data, source: :fetch)

      assert ResourceStore.data(key) == data
    end

    test "a body one byte over the size cap is refused" do
      key = ResourceStore.key(:issue, "owner", "repo", 6002)
      data = %{"b" => String.duplicate("x", 256 * 1024 - 7)}

      assert byte_size(Jason.encode!(data)) == 256 * 1024 + 1

      ResourceStore.put_resource(key, data, source: :fetch)

      assert ResourceStore.data(key) == nil,
             "an oversized body must not be held; the reader falling back to a fetch is the pre-store behavior"
    end

    # The retention half of the sweep, asserted through the sweep itself rather
    # than through a restart, because the deletion is a conditional
    # `select_delete/2` now: it must still drop what is genuinely past the window,
    # and it must leave alone an entry a writer refreshed after the sweep decided
    # about it — which a collect-then-delete pass could not.
    test "the sweep drops what is past the retention window and keeps what a writer refreshed" do
      ResourceStore.reset()
      now = System.system_time(:millisecond)
      store = Process.whereis(ResourceStore)

      stale = {:issue, "owner", "repo", "9001"}
      fresh = {:issue, "owner", "repo", "9002"}

      :ets.insert(ResourceStore.Table, {stale, %{recorded_at_ms: now - 73 * 60 * 60 * 1000}})
      :ets.insert(ResourceStore.Table, {fresh, %{recorded_at_ms: now - 1000}})

      send(store, :sweep)
      _state = :sys.get_state(store)

      assert :ets.lookup(ResourceStore.Table, stale) == []
      assert [_kept] = :ets.lookup(ResourceStore.Table, fresh)
    end

    # The other half of the same decision: an entry whose `recorded_at_ms` is
    # itself past cutoff has had no write in the whole window, so *nothing* in
    # it is in use any more — the body goes with the mark and the validator, as
    # a whole entry. The body's own age does not matter here: it is the
    # recorded_at that says whether the entry is dead.
    test "the sweep deletes a body-holding entry whose recorded_at is itself past retention" do
      ResourceStore.reset()
      now = System.system_time(:millisecond)
      store = Process.whereis(ResourceStore)

      key = {:issue_comment, "owner", "repo", "9100"}

      :ets.insert(ResourceStore.Table, {key, %{data: %{"body" => "ancient"}, recorded_at_ms: now - 73 * 60 * 60 * 1000}})

      send(store, :sweep)
      _state = :sys.get_state(store)

      assert :ets.lookup(ResourceStore.Table, key) == [],
             "a whole entry past retention is deleted, body and mark together"
    end

    # The trap the old sweep fell into: `recorded_at_ms` is bumped by *every*
    # write, so a body past retention whose entry a later non-body write touched
    # (a poll republish re-marking a processed comment, a `304` re-recording a
    # validator) never looked old to a sweep that judged the entry by that field.
    # The body must be judged by `fetched_at_ms` — the same field `fetch/1`
    # refuses on — so "past retention" means the same thing to the sweep, the
    # read and the page.
    #
    # Dropping the body is not the same as deleting the entry: the processed
    # mark and the ETag live on the same map, and both are still in use. Losing
    # the mark would make the poller republish a comment it already handled; the
    # ETag is what makes the next read free. So the sweep must remove the body
    # and keep everything else — the entry stands, `processed?` still answers,
    # and the validator still answers change detection by name.
    test "the sweep drops a body past retention but keeps the mark and the ETag" do
      ResourceStore.reset()
      now = System.system_time(:millisecond)
      store = Process.whereis(ResourceStore)

      key = ResourceStore.key(:issue_comment, "owner", "repo", 9101)
      ResourceStore.put_resource(key, %{"body" => "ancient"}, source: :webhook, version: "v1", etag: ~s("v1"))

      # Age the body past retention, then let a non-body write touch the entry —
      # exactly what a steady-state republish does to a long-lived comment.
      [{^key, entry}] = :ets.lookup(ResourceStore.Table, key)
      aged = Map.put(entry, :fetched_at_ms, now - 73 * 60 * 60 * 1000)
      :ets.insert(ResourceStore.Table, {key, aged})
      ResourceStore.mark_processed(key, :webhook, "v1")

      send(store, :sweep)
      _state = :sys.get_state(store)

      # Asserted on the entry, not through `data/1`/`fetch/1`: both readers
      # declined an expired body on main already, so only the entry can prove
      # the sweep actually removed the body. `:1600` binds `kept` and then
      # discards it — that binding is now load-bearing.
      assert [{^key, kept}] = :ets.lookup(ResourceStore.Table, key),
             "the entry itself must survive; only the body goes"

      refute Map.has_key?(kept, :data),
             "the expired body must actually leave the entry, not merely be hidden on read"

      refute Map.has_key?(kept, :data_version),
             "the body's version must leave with the body"

      assert ResourceStore.processed?(key, "v1"),
             "the processed mark must survive the sweep, or the poller republishes"

      assert ResourceStore.change_validator(key) == ~s("v1"),
             "the ETag must survive the sweep, or the next read pays full price"
    end

    # The nil/absent edge of pass 2. `body_expired?/2` reads a missing
    # `fetched_at_ms` as the epoch (`|| 0`), and pass 2's key collection must
    # agree with that predicate — otherwise a body the read declines is never
    # swept, "stale" forever. The match spec has explicit arms for the nil and
    # absent shapes, because Erlang's term order sorts atoms after numbers, so
    # `nil < cutoff` is `false` and a plain `:<` guard skips them.
    test "the sweep drops a body whose fetched_at_ms is nil or absent" do
      ResourceStore.reset()
      store = Process.whereis(ResourceStore)

      nil_key = {:issue_comment, "owner", "repo", "9102"}
      absent_key = {:issue_comment, "owner", "repo", "9103"}

      :ets.insert(ResourceStore.Table, {nil_key, %{data: %{"body" => "nil age"}, fetched_at_ms: nil}})
      :ets.insert(ResourceStore.Table, {absent_key, %{data: %{"body" => "no age"}}})

      send(store, :sweep)
      _state = :sys.get_state(store)

      assert [{^nil_key, nil_kept}] = :ets.lookup(ResourceStore.Table, nil_key),
             "the nil-aged entry must survive; only its body goes"

      refute Map.has_key?(nil_kept, :data),
             "a body with a nil fetched_at_ms must be dropped by the sweep, matching body_expired?/2"

      assert [{^absent_key, absent_kept}] = :ets.lookup(ResourceStore.Table, absent_key),
             "the absent-aged entry must survive; only its body goes"

      refute Map.has_key?(absent_kept, :data),
             "a body with an absent fetched_at_ms must be dropped by the sweep, matching body_expired?/2"
    end

    # The hard backstop. It used to delete whole entries, which destroyed the
    # `:etag` and `:processed_at_ms` beside the body — a comment an agent had
    # already handled would republish once the in-memory dedup window closed or
    # the daemon restarted, which is the one loss the retention window does not
    # cause. The backstop now sheds only the body, so the state that is still
    # correct survives, and the newest entries keep their answers.
    #
    # Asserted as "drops bodies from the oldest down to exactly the ceiling",
    # which fails both ways: a lower ceiling leaves more bodies, a higher one
    # leaves the overflow body in place.
    test "the entry ceiling drops the oldest bodies and keeps their marks and validators" do
      ResourceStore.reset()
      now = System.system_time(:millisecond)
      store = Process.whereis(ResourceStore)

      rows =
        for index <- 1..100_001 do
          {{:issue, "owner", "repo", Integer.to_string(index)},
           %{
             data: %{"number" => index, "state" => "open"},
             etag: ~s("e#{index}"),
             processed_at_ms: now,
             # `:version` is the version the pipe processed; `:data_version` is
             # the version of the body held (`fetch/1` reports it as the answer's
             # `:version`). Both must be present so the eviction assertion can
             # pin that `:data_version` is shed with its body.
             version: "v1",
             data_version: "v1",
             # `fetch/1` judges freshness on the body's own stamp, so a body
             # with no `fetched_at_ms` reads as ancient and is declined.
             fetched_at_ms: now,
             recorded_at_ms: now - (100_001 - index)
           }}
        end

      :ets.insert(ResourceStore.Table, rows)
      assert ResourceStore.size() == 100_001

      send(store, :sweep)
      # `:sys.get_state/1` returns only after every earlier message is handled,
      # so the sweep has finished by the time it answers.
      _state = :sys.get_state(store)

      # The oldest entry is spared as an entry: its body is shed, but the
      # validator and the processed mark survive the eviction. The body is
      # asserted on the entry itself, not through `fetch/1` — the reader API
      # declines an absent body on its own, so only the entry map proves the
      # eviction actually dropped `:data` rather than merely hiding it.
      oldest = {:issue, "owner", "repo", "1"}
      assert [{^oldest, kept}] = :ets.lookup(ResourceStore.Table, oldest)
      refute Map.has_key?(kept, :data)
      refute Map.has_key?(kept, :data_version)
      assert ResourceStore.fetch(oldest) == :miss
      assert ResourceStore.change_validator(oldest) == ~s("e1")
      assert ResourceStore.processed?(oldest, "v1")

      # Exactly the ceiling worth of bodies is left: only the overflow body was
      # shed, so the second-oldest entry still serves its `:data` — pinning the
      # count, so shedding 50,001 bodies instead of one could not pass — and the
      # newest entry is served without anyone paying for it again.
      second = {:issue, "owner", "repo", "2"}
      assert [{^second, kept2}] = :ets.lookup(ResourceStore.Table, second)
      assert Map.has_key?(kept2, :data)
      assert ResourceStore.size() == 100_001
      assert {:ok, %{data: %{"number" => 100_001}}} = ResourceStore.fetch({:issue, "owner", "repo", "100001"})
    end

    # The bound an unversioned mark suppresses for. `view_state_sweep_test.exs`
    # asserts the behaviour at this boundary, but computes its offsets from
    # `unversioned_suppression_ms/0` — so it moves with the constant and cannot
    # fail when the value changes. It also range-asserts 5 minutes to 2 hours,
    # which leaves a 24x span free. These use literals, so the value itself is
    # pinned rather than merely bounded.
    test "an unversioned mark suppresses just inside the bound" do
      key = ResourceStore.key(:issue_comment, "owner", "repo", 6101)
      ResourceStore.mark_processed(key, :poll)
      age_mark!(key, 30 * 60 * 1000 - 60 * 1000)

      assert ResourceStore.processed?(key)
    end

    test "an unversioned mark has stopped suppressing just outside the bound" do
      key = ResourceStore.key(:issue_comment, "owner", "repo", 6102)
      ResourceStore.mark_processed(key, :poll)
      age_mark!(key, 30 * 60 * 1000 + 60 * 1000)

      refute ResourceStore.processed?(key)
    end

    # A versioned mark is the contrast that makes the case above mean something:
    # same age, same key shape, and it still suppresses, because a version is
    # what earns the full retention window.
    test "a versioned mark outlives the unversioned bound" do
      key = ResourceStore.key(:issue_comment, "owner", "repo", 6103)
      ResourceStore.mark_processed(key, :poll, "2026-08-17T00:00:00Z")
      age_mark!(key, 30 * 60 * 1000 + 60 * 1000)

      assert ResourceStore.processed?(key, "2026-08-17T00:00:00Z")
    end

    # The sweep cadence has no observable consequence inside a test's lifetime,
    # so it is asserted where it is set: the timer the sweep re-arms for itself.
    test "the sweep re-arms on its five-minute cadence" do
      store = Process.whereis(ResourceStore)

      :erlang.trace_pattern({:erlang, :send_after, 3}, true, [:global])
      :erlang.trace(store, true, [:call])

      on_exit(fn ->
        :erlang.trace_pattern({:erlang, :send_after, 3}, false, [:global])
      end)

      send(store, :sweep)

      assert_receive {:trace, ^store, :call, {:erlang, :send_after, [300_000, _dest, :sweep]}}, 2_000

      :erlang.trace(store, false, [:call])
    end
  end
end

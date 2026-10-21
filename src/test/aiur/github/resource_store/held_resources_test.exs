defmodule Aiur.GitHub.ResourceStore.HeldResourcesTest do
  use Aiur.TestSupport
  use Aiur.ResourceStoreTestSupport

  alias Aiur.GitHub.ResourceFetch
  alias Aiur.GitHub.ResourceStore

  describe "held resources" do
    test "a body written by one reader serves the next with no upstream call" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 7)
      assert ResourceStore.fetch(key) == :miss

      ResourceStore.put_resource(key, %{"title" => "hello"}, etag: "W/\"abc\"", source: :fetch)

      assert ResourceStore.data(key) == %{"title" => "hello"}
      assert ResourceStore.etag(key) == "W/\"abc\""
    end

    # R7: freshness is explicit per entry, so a consumer can state the staleness
    # it tolerates. An entry that cannot say when or from where it was recorded
    # forces every consumer to either trust it blindly or refetch.
    test "an entry carries its own freshness" do
      key = ResourceStore.key(:pull_request, "owner", "repo", 12)
      before_ms = System.system_time(:millisecond)

      ResourceStore.put_resource(key, %{"number" => 12},
        source: :webhook,
        version: "2026-08-17T10:00:00Z",
        etag: "W/\"pr\""
      )

      assert {:ok, entry} = ResourceStore.fetch(key)
      assert entry.data == %{"number" => 12}
      assert entry.source == :webhook
      assert entry.version == "2026-08-17T10:00:00Z"
      assert entry.etag == "W/\"pr\""
      assert entry.fetched_at_ms >= before_ms
    end

    # Two consumers inside one freshness window cost one upstream call. The
    # assertion is the call count, because that is the thing that shows up on the
    # rate limit; latency would pass against a cache that never hits.
    # Read through `ResourceFetch.need/3`, the real read-before-spend path, so
    # the counted function is the one an upstream request would actually leave
    # through. A hand-rolled `case` in the test counts only whether
    # `ResourceStore.fetch/1` missed, which is a weaker claim than "one upstream
    # call" and would pass against a path that never consulted the store at all.
    test "the second consumer of a resource costs no upstream call" do
      key = ResourceStore.key(:pull_request, "owner", "repo", 13)
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      upstream = fn _opts ->
        Agent.update(calls, &(&1 + 1))
        {:ok, %{"number" => 13}, "W/\"pr13\""}
      end

      assert {:ok, %{"number" => 13}, %{outcome: :fetched, spent?: true}} =
               ResourceFetch.need(key, upstream, freshness: :any)

      assert {:ok, %{"number" => 13}, %{outcome: :store, spent?: false}} =
               ResourceFetch.need(key, upstream, freshness: :any)

      assert {:ok, %{"number" => 13}, %{outcome: :store, spent?: false}} =
               ResourceFetch.need(key, upstream, freshness: :any)

      assert Agent.get(calls, & &1) == 1
    end

    # The rule this feature turns on: a 304 is not data. A validator alone is
    # still worth keeping — a reader that only wants change detection asks
    # `change_validator/1` for it — but it can never serve a reader of bodies,
    # so `fetch/1` misses and `etag/1` declines rather than let a caller mistake
    # "unchanged" for "here it is".
    test "a validator without a body never serves a reader" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 8)
      ResourceStore.put_etag(key, "W/\"abc\"")

      assert ResourceStore.change_validator(key) == "W/\"abc\"", "change detection survives"
      assert ResourceStore.etag(key) == nil, "but a reader of bodies is not offered it"
      assert ResourceStore.fetch(key) == :miss, "and it must not be mistaken for data"
      assert ResourceStore.data(key) == nil
    end

    test "dropping a body keeps change detection" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 11)
      ResourceStore.put_resource(key, %{"title" => "hello"}, etag: "W/\"abc\"")

      ResourceStore.drop_data(key)

      assert ResourceStore.fetch(key) == :miss
      assert ResourceStore.change_validator(key) == "W/\"abc\""
      assert ResourceStore.etag(key) == nil
    end

    # A refusal means "I cannot hold what you sent", never "what you are holding
    # is wrong". Destroying a good body over a refused arrival would throw away
    # state already paid for and make the next reader buy it again — while
    # keeping the old validator, which is the bodyless pair every other path
    # here refuses.
    test "an oversized body is refused and the held body survives it" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 9)
      ResourceStore.put_resource(key, %{"small" => true}, etag: "W/\"old\"")
      [{^key, before}] = :ets.lookup(ResourceStore.Table, key)

      huge = %{"blob" => String.duplicate("x", 300 * 1024)}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          ResourceStore.put_resource(key, huge, etag: "W/\"new\"")
        end)

      assert log =~ "refused an oversized body"
      assert ResourceStore.data(key) == %{"small" => true}, "the held body must survive a refused arrival"
      assert ResourceStore.etag(key) == "W/\"old\"", "and keep the validator that describes it"

      [{^key, entry}] = :ets.lookup(ResourceStore.Table, key)

      assert Map.get(entry, :fetched_at_ms) == Map.get(before, :fetched_at_ms),
             "a deposit that stored nothing must not make the held body look younger"
    end

    # A body the checkpoint could never render is refused at the door rather
    # than accepted and then quietly dropped — or worse, raised on, at the next
    # checkpoint, where it would take every unrelated entry down with it.
    test "a body JSON cannot encode is refused like an oversized one" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 16)
      ResourceStore.put_resource(key, %{"was" => "here"}, etag: "W/\"old\"")

      ExUnit.CaptureLog.capture_log(fn ->
        ResourceStore.put_resource(key, %{"pid" => self(), "tuple" => {1, 2}}, etag: "W/\"new\"")
      end)

      assert ResourceStore.data(key) == %{"was" => "here"}
      assert ResourceStore.etag(key) == "W/\"old\""
      assert :ok = ResourceStore.flush()
    end

    # A deposit that supplies no validator has to say something about the one
    # already held, and the honest answer depends on the body. A webhook
    # delivery is the case that matters: it carries a fresh body and no
    # validator of any kind, so keeping the old one guaranteed that every later
    # conditional read would miss — the entry could never earn a `304` again.
    test "a changed body deposited without a validator discards the stale one" do
      key = ResourceStore.key(:issue, "owner", "repo", 8410)
      ResourceStore.put_resource(key, %{"state" => "open"}, etag: ~s("v1"))

      ResourceStore.put_resource(key, %{"state" => "closed"}, source: :webhook, version: "2026-08-17T12:00:00Z")

      assert ResourceStore.data(key) == %{"state" => "closed"}
      assert ResourceStore.etag(key) == nil, "a validator for the previous body cannot describe this one"
      assert ResourceStore.change_validator(key) == nil
    end

    test "an unchanged body deposited without a validator keeps it" do
      key = ResourceStore.key(:issue, "owner", "repo", 8411)
      ResourceStore.put_resource(key, %{"state" => "open"}, etag: ~s("v1"))

      ResourceStore.put_resource(key, %{"state" => "open"}, source: :webhook, version: "2026-08-17T12:00:00Z")

      assert ResourceStore.etag(key) == ~s("v1"), "the held validator still describes this exact body"
    end

    test "a deposit that supplies a validator always records it" do
      key = ResourceStore.key(:issue, "owner", "repo", 8412)
      ResourceStore.put_resource(key, %{"state" => "open"}, etag: ~s("v1"))

      ResourceStore.put_resource(key, %{"state" => "closed"}, etag: ~s("v2"))

      assert ResourceStore.etag(key) == ~s("v2")
    end

    # R8/A7. Without the body on disk a restart keeps every validator and loses
    # every answer, so the first reader after a boot sends `If-None-Match`, gets a
    # bodyless 304, and has to pay full price anyway.
    test "a body survives a restart, and so does its validator", %{path: path} do
      restart_store!(path)
      key = ResourceStore.key(:issue_comments, "owner", "repo", 10)

      ResourceStore.put_resource(key, %{"title" => "durable"},
        etag: "W/\"keep\"",
        source: :fetch,
        version: "2026-08-17T09:00:00Z"
      )

      assert :ok = ResourceStore.flush()

      restart_store!(path)

      assert {:ok, entry} = ResourceStore.fetch(key)
      assert entry.data == %{"title" => "durable"}
      assert entry.version == "2026-08-17T09:00:00Z"
      assert entry.source == :fetch
      assert ResourceStore.etag(key) == "W/\"keep\""
    end

    # The eviction sweep runs every five minutes, so between sweeps an entry can
    # outlive the window it is allowed to answer for. A read must decline it
    # rather than hand back a body nothing has revalidated for three days.
    test "a body older than the retention window is not served" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 15)
      ResourceStore.put_resource(key, %{"title" => "ancient"})
      assert {:ok, _entry} = ResourceStore.fetch(key)

      [{^key, entry}] = :ets.lookup(ResourceStore.Table, key)
      aged = Map.put(entry, :fetched_at_ms, System.system_time(:millisecond) - 73 * 60 * 60 * 1000)
      :ets.insert(ResourceStore.Table, {key, aged})

      assert ResourceStore.fetch(key) == :miss
      assert ResourceStore.data(key) == nil
    end

    # The trap this closes: every write touches `recorded_at_ms`, so judging the
    # body by that field would let a sweep re-recording an unchanged validator
    # keep a three-day-old body servable forever.
    test "re-recording a validator does not renew an expired body" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 17)
      ResourceStore.put_resource(key, %{"title" => "ancient"})

      [{^key, entry}] = :ets.lookup(ResourceStore.Table, key)
      aged = Map.put(entry, :fetched_at_ms, System.system_time(:millisecond) - 73 * 60 * 60 * 1000)
      :ets.insert(ResourceStore.Table, {key, aged})

      ResourceStore.put_etag(key, "W/\"swept\"")

      assert ResourceStore.fetch(key) == :miss
    end

    # A deposit is not a processed mark. Merging them would let a writer drag the
    # suppression mark forward onto a version nothing has handled, and the wake
    # for that version would never happen.
    test "depositing a body does not silently suppress the resource" do
      key = ResourceStore.key(:issue_comment, "owner", "repo", 14)

      ResourceStore.put_resource(key, %{"body" => "hi"}, version: "v1")

      refute ResourceStore.processed?(key, "v1")

      ResourceStore.put_resource(key, %{"body" => "hi"}, version: "v1", processed: true)

      assert ResourceStore.processed?(key, "v1")
      refute ResourceStore.processed?(key, "v2")
    end

    # A mark with no version suppresses on identity alone, which swallows that
    # resource's next genuine change for the whole retention window. Asking for
    # one is refused out loud rather than honoured quietly.
    test "a processed mark with no version is refused and logged" do
      key = ResourceStore.key(:issue_comment, "owner", "repo", 18)
      ResourceStore.mark_processed(key, :webhook, "v1")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          ResourceStore.put_resource(key, %{"body" => "no version here"}, processed: true)
        end)

      assert log =~ "processed: true with no version"
      assert ResourceStore.processed?(key, "v1"), "the earlier versioned mark must stand"
      refute ResourceStore.processed?(key, nil)
    end
  end

  describe "list_type/2 — enumerating a type's held bodies" do
    test "lists only the bodies of one type within one repository" do
      ResourceStore.reset()

      ResourceStore.put_resource(ResourceStore.key(:issue, "owner", "repo", 1), %{"number" => 1})
      ResourceStore.put_resource(ResourceStore.key(:issue, "owner", "repo", 2), %{"number" => 2})
      # Same type, different repo; and same repo, different type — neither may
      # leak into the answer.
      ResourceStore.put_resource(ResourceStore.key(:issue, "other", "repo", 3), %{"number" => 3})
      ResourceStore.put_resource(ResourceStore.key(:issue_labels, "owner", "repo", 2), [%{"name" => "x"}])

      assert ResourceStore.list_type(:issue, "owner/repo")
             |> Enum.sort_by(&elem(&1, 0)) == [
               {ResourceStore.key(:issue, "owner", "repo", 1), %{"number" => 1}},
               {ResourceStore.key(:issue, "owner", "repo", 2), %{"number" => 2}}
             ]
    end

    test "an entry holding no body and an expired entry are both omitted" do
      ResourceStore.reset()

      body_key = ResourceStore.key(:issue, "owner", "repo", 1)
      ResourceStore.put_resource(body_key, %{"number" => 1})
      # A validator with no body is legitimate and must not be served here.
      ResourceStore.put_etag(ResourceStore.key(:issue, "owner", "repo", 2), "W/\"v2\"")
      # An expired body must be omitted exactly as `fetch/1` omits it. The body's
      # `fetched_at_ms` is what `fetch/1` judges, so age it past the 72-hour
      # retention window directly.
      expired_key = ResourceStore.key(:issue, "owner", "repo", 3)

      :ets.insert(Aiur.GitHub.ResourceStore.Table, {expired_key, %{data: %{"number" => 3}, fetched_at_ms: 0}})

      assert [{^body_key, %{"number" => 1}}] = ResourceStore.list_type(:issue, "owner/repo")
    end

    test "answers [] for a malformed repo or an unlisted type" do
      ResourceStore.reset()
      ResourceStore.put_resource(ResourceStore.key(:issue, "owner", "repo", 1), %{"number" => 1})

      assert ResourceStore.list_type(:issue, "owner") == []
      assert ResourceStore.list_type(:issue, nil) == []
      assert ResourceStore.list_type(:not_a_type, "owner/repo") == []
    end
  end

  describe "a validator never outlives the body it validates" do
    # `deposit_etag/3` refuses a validator for a refused body, but it only sees
    # the deposit. The checkpoint is the other place the pair comes apart: an
    # entry consistent in memory whose body the encoder cannot render used to be
    # written as a validator alone, so the next boot sent `If-None-Match`, was
    # answered `304`, and held nothing — a spent request that returns no data.
    # Inserted straight into the table because the deposit gate now refuses this
    # shape at the door; the checkpoint must refuse it too.
    test "a body the checkpoint cannot render takes its validator with it", %{path: path} do
      restart_store!(path)
      key = ResourceStore.key(:issue_comments, "owner", "repo", 620)
      now = System.system_time(:millisecond)

      :ets.insert(
        ResourceStore.Table,
        {key, %{etag: ~s("fresh"), data: %{id: 620}, fetched_at_ms: now, recorded_at_ms: now}}
      )

      log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = ResourceStore.flush() end)
      assert log =~ "cannot checkpoint the body"

      restart_store!(path)

      assert ResourceStore.fetch(key) == :miss
      assert ResourceStore.etag(key) == nil, "a validator with no body earns a 304 and no data"
    end

    # The same pair, produced the honest way: a body the store *can* hold has to
    # survive the checkpoint, or the validator beside it is the bodyless kind
    # again. A scalar is JSON that round-trips, so it is held rather than dropped.
    test "a scalar body and its validator both survive a restart", %{path: path} do
      restart_store!(path)
      key = ResourceStore.key(:issue_comments, "owner", "repo", 621)

      assert :ok = ResourceStore.put_resource(key, "a scalar body", etag: ~s("fresh"))
      assert :ok = ResourceStore.flush()

      restart_store!(path)

      assert ResourceStore.data(key) == "a scalar body"
      assert ResourceStore.etag(key) == ~s("fresh")
    end

    # A body that comes back in a different shape than it went in is worse than
    # no body: a consumer matching `%{id: id}` works until the next restart and
    # then raises, with nothing to attribute it to. Refused at the door, out
    # loud, and identically before and after a restart.
    test "an atom-keyed body is refused rather than silently re-shaped", %{path: path} do
      restart_store!(path)
      key = ResourceStore.key(:issue_comments, "owner", "repo", 622)
      ResourceStore.put_resource(key, %{"kept" => true}, etag: ~s("old"))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = ResourceStore.put_resource(key, %{id: 622, body: "hi"}, etag: ~s("new"))
        end)

      assert log =~ "JSON cannot round-trip"
      assert ResourceStore.data(key) == %{"kept" => true}, "the refused body must not destroy the held one"
      assert ResourceStore.etag(key) == ~s("old"), "which is still the validator that describes it"

      assert :ok = ResourceStore.flush()
      restart_store!(path)

      assert ResourceStore.data(key) == %{"kept" => true}, "and the answer is the same after a restart as before it"
    end

    test "a struct body is refused for the same reason" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 623)

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = ResourceStore.put_resource(key, %{"at" => DateTime.utc_now()}, etag: ~s("x"))
      end)

      assert ResourceStore.fetch(key) == :miss
      assert ResourceStore.etag(key) == nil
    end
  end

  describe "a write never raises" do
    # `ResourceEvents.type_topic/1` had only an `is_atom` clause, so a key built
    # by hand with a string type raised `FunctionClauseError` out of the write —
    # after the ETS insert had already landed. The entry was written and the
    # caller died, which in a poll task kills the whole cycle. `with_table/2`'s
    # `rescue ArgumentError` catches neither this nor the interpolation below.
    test "a non-atom resource type is written and announced to nobody" do
      key = {"issue_comment", "owner", "repo", "1"}

      assert :ok = ResourceStore.put_etag(key, ~s("x"))
      assert ResourceStore.change_validator(key) == ~s("x")
    end

    test "a non-binary owner or repo is written and announced to nobody" do
      assert :ok = ResourceStore.put_resource({:issue_comment, %{}, "repo", "1"}, %{"a" => 1})
      assert :ok = ResourceStore.put_resource({:issue_comment, "owner", 7, "1"}, %{"a" => 1})
      assert :ok = ResourceStore.put_etag({:issue_comment, "owner", nil, "1"}, ~s("x"))
    end

    test "no read raises on a key nothing can address" do
      key = {"issue_comment", %{}, 7, :one}

      assert ResourceStore.etag(key) == nil
      assert ResourceStore.fetch(key) == :miss
      assert ResourceStore.data(key) == nil
      refute ResourceStore.processed?(key, "v1")
      assert :ok = ResourceStore.drop_data(key)
      assert :ok = ResourceStore.drop_etag(key)
    end
  end

  # What a `304` is allowed to write. It confirms the validator its caller sent
  # against the body its caller held, and nothing more — since #2106 the webhook
  # pipe deposits bodies on these same keys, so "nothing more" is load-bearing.
end

defmodule Aiur.GitHub.ResourceStoreTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.ResourceStore

  setup do
    dir = Path.join(System.tmp_dir!(), "aiur-resource-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "github_resources.json")

    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, path: path, dir: dir}
  end

  describe "resource identity" do
    test "keys are addressed by resource, not by call site" do
      assert ResourceStore.key(:issue_comment, "owner", "repo", 42) ==
               {:issue_comment, "owner", "repo", "42"}

      # An integer id and its string form are the same resource.
      assert ResourceStore.key(:issue_comment, "owner", "repo", 42) ==
               ResourceStore.key(:issue_comment, "owner", "repo", "42")
    end

    # The poller names the repo from configuration and the webhook names it from
    # GitHub's delivered `repository.full_name`. Those two strings are not
    # guaranteed to agree on case, and an exact-match store would then hold two
    # entries for one comment — so both pipes would process it and the whole
    # mechanism would silently do nothing.
    test "owner and repo casing cannot split one resource into two entries" do
      assert ResourceStore.key(:issue_comment, "Owner", "Repo", 42) ==
               ResourceStore.key(:issue_comment, "owner", "repo", 42)

      assert ResourceStore.key_for_repo(:issue_comment, "Owner/Repo", 42) ==
               ResourceStore.key_for_repo(:issue_comment, "owner/repo", 42)
    end

    test "an unusable identity answers nil rather than a key nothing else can find" do
      assert ResourceStore.key(:issue_comment, "owner", "repo", nil) == nil
      assert ResourceStore.key(:issue_comment, "owner", "repo", "") == nil
      assert ResourceStore.key_for_repo(:issue_comment, "not-a-repo", 42) == nil
      assert ResourceStore.key_for_repo(:issue_comment, nil, 42) == nil
    end
  end

  describe "processed marks" do
    test "records and reports which resources a pipe has handled" do
      key = ResourceStore.key(:issue_comment, "owner", "repo", 9001)

      refute ResourceStore.processed?(key)
      assert :ok = ResourceStore.mark_processed(key, :webhook)
      assert ResourceStore.processed?(key)
    end

    test "a nil key is never processed and marking it is a no-op" do
      refute ResourceStore.processed?(nil)
      assert :ok = ResourceStore.mark_processed(nil, :webhook)
    end

    test "claim reports the first caller and every later one distinctly" do
      key = ResourceStore.key(:issue_comment, "owner", "repo", 9002)

      assert :marked = ResourceStore.claim(key, :webhook)
      assert :already_processed = ResourceStore.claim(key, :poll)
    end

    # A GitHub comment's id survives an edit; only `updated_at` moves. Without
    # the version an edited comment would read as already processed for the full
    # 72-hour window, so the operator's correction would never wake the agent.
    test "a resource whose version moved reads as unprocessed" do
      key = ResourceStore.key(:issue_comment, "owner", "repo", 9010)

      ResourceStore.mark_processed(key, :webhook, "2026-08-17T10:00:00Z")

      assert ResourceStore.processed?(key, "2026-08-17T10:00:00Z")
      refute ResourceStore.processed?(key, "2026-08-17T12:00:00Z")
    end

    test "re-marking at the new version suppresses that version in turn" do
      key = ResourceStore.key(:issue_comment, "owner", "repo", 9011)

      ResourceStore.mark_processed(key, :webhook, "2026-08-17T10:00:00Z")
      ResourceStore.mark_processed(key, :poll, "2026-08-17T12:00:00Z")

      assert ResourceStore.processed?(key, "2026-08-17T12:00:00Z")
      refute ResourceStore.processed?(key, "2026-08-17T10:00:00Z")
    end

    test "claim treats a moved version as a fresh resource state" do
      key = ResourceStore.key(:issue_comment, "owner", "repo", 9012)

      assert :marked = ResourceStore.claim(key, :webhook, "2026-08-17T10:00:00Z")
      assert :already_processed = ResourceStore.claim(key, :poll, "2026-08-17T10:00:00Z")
      assert :marked = ResourceStore.claim(key, :poll, "2026-08-17T12:00:00Z")
    end

    # A resource with no readable version keeps the pre-version behavior rather
    # than looking edited on every read, which would republish the whole window
    # every cycle.
    test "a versionless resource is suppressed on identity alone" do
      key = ResourceStore.key(:pr_review, "owner", "repo", 9013)

      ResourceStore.mark_processed(key, :webhook, nil)

      assert ResourceStore.processed?(key, nil)
      assert ResourceStore.processed?(key)
      refute ResourceStore.processed?(key, "2026-08-17T12:00:00Z")
    end

    # Marking one resource must not answer for its siblings, which is the whole
    # reason suppression is keyed by identity rather than by a timestamp
    # watermark: an older comment whose delivery was dropped is a different
    # resource, not an earlier version of this one.
    test "a mark answers only for the resource it names" do
      delivered = ResourceStore.key(:issue_comment, "owner", "repo", 9004)
      dropped = ResourceStore.key(:issue_comment, "owner", "repo", 9003)

      ResourceStore.mark_processed(delivered, :webhook)

      assert ResourceStore.processed?(delivered)
      refute ResourceStore.processed?(dropped)
    end
  end

  describe "etags" do
    test "stores and returns a validator" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 42)

      assert ResourceStore.etag(key) == nil
      assert :ok = ResourceStore.put_etag(key, ~s("abc123"))
      assert ResourceStore.etag(key) == ~s("abc123")
    end

    test "an absent validator is never invented" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 43)

      ResourceStore.put_etag(key, nil)
      ResourceStore.put_etag(key, "")

      assert ResourceStore.etag(key) == nil
    end

    test "a validator and a processed mark coexist on one resource" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 44)

      ResourceStore.put_etag(key, ~s("v1"))
      ResourceStore.mark_processed(key, :poll)

      assert ResourceStore.etag(key) == ~s("v1")
      assert ResourceStore.processed?(key)
    end
  end

  describe "surviving restart" do
    # #2069 acceptance criterion 5. An in-memory-only cache re-pays full price
    # on every boot, and boots are routine here: without this, the first sweep
    # after each restart reads every watched ticket's comment list unconditioned.
    test "validators and marks are reloaded from the checkpoint", %{path: path} do
      etag_key = ResourceStore.key(:issue_comments, "owner", "repo", 77)
      mark_key = ResourceStore.key(:issue_comment, "owner", "repo", 5150)

      restart_store!(path)

      ResourceStore.put_etag(etag_key, ~s("survives"))
      ResourceStore.mark_processed(mark_key, :webhook, "2026-08-17T10:00:00Z")
      assert :ok = ResourceStore.flush()
      assert File.exists?(path)

      restart_store!(path)

      assert ResourceStore.etag(etag_key) == ~s("survives")
      assert ResourceStore.processed?(mark_key, "2026-08-17T10:00:00Z")
    end

    # The version has to round-trip too, or a restart would resurrect the very
    # bug it prevents: the mark survives, the version does not, and an edit made
    # before the restart looks already-processed after it.
    test "a version survives the checkpoint so an edit still re-publishes", %{path: path} do
      key = ResourceStore.key(:issue_comment, "owner", "repo", 5160)

      restart_store!(path)

      ResourceStore.mark_processed(key, :webhook, "2026-08-17T10:00:00Z")
      assert :ok = ResourceStore.flush()

      restart_store!(path)

      assert ResourceStore.processed?(key, "2026-08-17T10:00:00Z")
      refute ResourceStore.processed?(key, "2026-08-17T12:00:00Z")
    end

    # Failing open is the rule everywhere in this store: a cache that cannot
    # answer costs a full-price sweep, which is exactly the pre-store behavior,
    # and refusing to boot over a bad file would be strictly worse.
    test "a corrupt checkpoint starts cold instead of failing", %{path: path} do
      File.write!(path, "{ not json at all")

      log = ExUnit.CaptureLog.capture_log(fn -> restart_store!(path) end)

      assert log =~ "checkpoint unreadable"
      assert ResourceStore.etag(ResourceStore.key(:issue_comments, "owner", "repo", 78)) == nil
      refute ResourceStore.processed?(ResourceStore.key(:issue_comment, "owner", "repo", 5151))
    end

    test "an unknown resource type in a checkpoint is dropped, not resurrected", %{path: path} do
      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "entries" => %{
            "not_a_real_type|owner|repo|1" => %{
              "etag" => ~s("x"),
              "recorded_at_ms" => System.system_time(:millisecond)
            },
            "issue_comments|owner|repo|79" => %{
              "etag" => ~s("kept"),
              "recorded_at_ms" => System.system_time(:millisecond)
            }
          }
        })
      )

      restart_store!(path)

      assert ResourceStore.etag(ResourceStore.key(:issue_comments, "owner", "repo", 79)) == ~s("kept")
      assert ResourceStore.size() == 1, "the unknown type must be dropped, not resurrected as a new atom"
      assert ResourceStore.etag({:not_a_real_type, "owner", "repo", "1"}) == nil
    end

    # `:webhook`, `:poll`, `:mutation` and `:fetch` are resolvable atoms because
    # they name the `:source` field. That does not make them resource types: a
    # checkpoint naming one in the type slot used to decode into a key no `key/4`
    # can build and `encode_key/1` refuses on the way back out — an entry no
    # reader can reach that disappears again at the next checkpoint.
    test "a source atom in the type slot is not a resource type", %{path: path} do
      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "entries" => %{
            "webhook|owner|repo|1" => %{
              "etag" => ~s("smuggled"),
              "recorded_at_ms" => System.system_time(:millisecond)
            },
            "issue_comments|owner|repo|81" => %{
              "etag" => ~s("kept"),
              "recorded_at_ms" => System.system_time(:millisecond)
            }
          }
        })
      )

      restart_store!(path)

      assert ResourceStore.etag(ResourceStore.key(:issue_comments, "owner", "repo", 81)) == ~s("kept")
      assert ResourceStore.size() == 1, "a source atom must not decode into a resource key"
    end

    test "entries older than the retention window are not reloaded", %{path: path} do
      stale_ms = System.system_time(:millisecond) - 73 * 60 * 60 * 1000

      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "entries" => %{
            "issue_comment|owner|repo|5152" => %{
              "processed_at_ms" => stale_ms,
              "recorded_at_ms" => stale_ms
            }
          }
        })
      )

      restart_store!(path)

      refute ResourceStore.processed?(ResourceStore.key(:issue_comment, "owner", "repo", 5152))
    end
  end

  describe "degrading" do
    # The store is a cache with reconciliation, never the system of record. If it
    # is gone, every answer must be the one the caller would have given before
    # the store existed: no validator, nothing processed.
    test "every read answers storelessly when no store is running" do
      stop_store!()

      assert ResourceStore.etag(ResourceStore.key(:issue_comments, "owner", "repo", 80)) == nil
      refute ResourceStore.processed?(ResourceStore.key(:issue_comment, "owner", "repo", 5153))
      assert :ok = ResourceStore.put_etag(ResourceStore.key(:issue_comments, "owner", "repo", 80), ~s("x"))
      assert :ok = ResourceStore.mark_processed(ResourceStore.key(:issue_comment, "owner", "repo", 5153), :poll)
      assert ResourceStore.size() == 0
      assert :marked = ResourceStore.claim(ResourceStore.key(:issue_comment, "owner", "repo", 5153), :poll)
    end

    # The generalized surface has to degrade the same way the marks do: a reader
    # misses and fetches, a writer's deposit is accepted and dropped on the
    # floor. Neither may raise into a poll task or a LiveView mount.
    test "the resource surface answers storelessly too" do
      stop_store!()
      key = ResourceStore.key(:pull_request, "owner", "repo", 4242)

      assert ResourceStore.fetch(key) == :miss
      assert ResourceStore.data(key) == nil
      assert :ok = ResourceStore.put_resource(key, %{"number" => 4242}, source: :fetch, version: "v1")
      assert :ok = ResourceStore.drop_data(key)
      assert ResourceStore.fetch(key) == :miss
      assert :ok = ResourceStore.subscribe(key)
      assert :ok = ResourceStore.unsubscribe(key)
    end

    # A key built by hand can carry a member no topic can be made from. The
    # announcement is what must give way, never the write.
    test "a write survives a key no announcement can address" do
      key = {:issue_comment, "owner", "repo", 5154}

      assert :ok = ResourceStore.put_resource(key, %{"body" => "still stored"}, source: :fetch)
      assert ResourceStore.data(key) == %{"body" => "still stored"}
    end
  end

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
    test "the second consumer of a resource costs no upstream call" do
      key = ResourceStore.key(:pull_request, "owner", "repo", 13)
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      read = fn ->
        case ResourceStore.fetch(key) do
          {:ok, %{data: data}} ->
            data

          :miss ->
            Agent.update(calls, &(&1 + 1))
            data = %{"number" => 13}
            ResourceStore.put_resource(key, data, source: :fetch)
            data
        end
      end

      assert read.() == %{"number" => 13}
      assert read.() == %{"number" => 13}
      assert read.() == %{"number" => 13}

      assert Agent.get(calls, & &1) == 1
    end

    # The rule this feature turns on: a 304 is not data. A validator alone is
    # still worth keeping — the sweep uses it to learn *whether* anything
    # changed — but it can never serve a reader, so `fetch/1` must miss and force
    # a fetch rather than let a caller mistake "unchanged" for "here it is".
    test "a validator without a body never serves a reader" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 8)
      ResourceStore.put_etag(key, "W/\"abc\"")

      assert ResourceStore.etag(key) == "W/\"abc\"", "change detection survives"
      assert ResourceStore.fetch(key) == :miss, "but it must not be mistaken for data"
      assert ResourceStore.data(key) == nil
    end

    test "dropping a body keeps change detection" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 11)
      ResourceStore.put_resource(key, %{"title" => "hello"}, etag: "W/\"abc\"")

      ResourceStore.drop_data(key)

      assert ResourceStore.fetch(key) == :miss
      assert ResourceStore.etag(key) == "W/\"abc\""
    end

    # Refusing the body must not also record the validator that proves it
    # current. That pair would earn the next reader a `304` for a resource the
    # store does not hold — a spent request that returns no data, which is the
    # exact failure this store exists to remove. The older validator is stale, so
    # it earns a `200` with a body instead.
    test "an oversized body is refused, and its validator is refused with it" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 9)
      ResourceStore.put_resource(key, %{"small" => true}, etag: "W/\"old\"")

      huge = %{"blob" => String.duplicate("x", 300 * 1024)}
      ResourceStore.put_resource(key, huge, etag: "W/\"new\"")

      assert ResourceStore.fetch(key) == :miss, "an oversized body is refused, not stored"
      assert ResourceStore.etag(key) == "W/\"old\"", "a validator without its body would earn a bodyless 304"
    end

    # A body the checkpoint could never render is refused at the door rather
    # than accepted and then quietly dropped — or worse, raised on, at the next
    # checkpoint, where it would take every unrelated entry down with it.
    test "a body JSON cannot encode is refused like an oversized one" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 16)
      ResourceStore.put_resource(key, %{"was" => "here"}, etag: "W/\"old\"")

      ResourceStore.put_resource(key, %{"pid" => self(), "tuple" => {1, 2}}, etag: "W/\"new\"")

      assert ResourceStore.fetch(key) == :miss
      assert ResourceStore.etag(key) == "W/\"old\""
      assert :ok = ResourceStore.flush()
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
      assert ResourceStore.fetch(key) == :miss, "the refused body replaced the held one"
      assert ResourceStore.etag(key) == ~s("old"), "a refused body refuses its validator too"

      assert :ok = ResourceStore.flush()
      restart_store!(path)

      assert ResourceStore.data(key) == nil, "and the answer is the same after a restart as before it"
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
      assert ResourceStore.etag(key) == ~s("x")
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
  describe "revalidate/3" do
    test "confirms the held body, refreshes its window and installs the validator" do
      key = ResourceStore.key(:pull_request, "owner", "repo", 8300)
      body = %{"gen" => 1}
      ResourceStore.put_resource(key, body, source: :poll, version: "v1")
      {:ok, before} = ResourceStore.fetch(key)

      assert :confirmed = ResourceStore.revalidate(key, body, ~s("e8300"))

      {:ok, entry} = ResourceStore.fetch(key)
      assert entry.data == body
      assert entry.etag == ~s("e8300")
      assert entry.fetched_at_ms >= before.fetched_at_ms
      # The body did not change, so neither did what describes it.
      assert entry.version == "v1"
      assert entry.source == :poll
    end

    # The lost update this exists to prevent. A newer body means this caller's
    # `304` describes something the store no longer holds, so every field it
    # would have re-stamped is wrong — including, most dangerously, the
    # validator, which would then earn the next reader a `304` and a body it did
    # not validate.
    test "a body replaced underneath is left completely untouched" do
      key = ResourceStore.key(:pull_request, "owner", "repo", 8301)
      ResourceStore.put_resource(key, %{"gen" => 1}, source: :poll, version: "v1", etag: ~s("old"))
      stale_read = %{"gen" => 0}

      ResourceStore.put_resource(key, %{"gen" => 2}, source: :webhook, version: "v2", etag: ~s("new"))
      {:ok, before} = ResourceStore.fetch(key)

      assert :superseded = ResourceStore.revalidate(key, stale_read, ~s("mine"))

      {:ok, entry} = ResourceStore.fetch(key)
      assert entry.data == %{"gen" => 2}
      assert entry.version == "v2"
      assert entry.source == :webhook
      assert entry.etag == ~s("new")
      assert entry.fetched_at_ms == before.fetched_at_ms
    end

    test "a superseded revalidation wakes no subscriber, because it wrote nothing" do
      key = ResourceStore.key(:pull_request, "owner", "repo", 8302)
      ResourceStore.put_resource(key, %{"gen" => 2}, source: :webhook, version: "v2")
      ResourceStore.subscribe(key)

      assert :superseded = ResourceStore.revalidate(key, %{"gen" => 1}, ~s("mine"))

      refute_receive {:github_resource_changed, _change}, 100
    end

    test "answers :miss when no body is held, so the caller re-reads unconditionally" do
      key = ResourceStore.key(:pull_request, "owner", "repo", 8303)
      assert :miss = ResourceStore.revalidate(key, %{"gen" => 1}, ~s("mine"))

      # A validator with no body is the same case: there is nothing to confirm.
      ResourceStore.put_etag(key, ~s("orphan"))
      assert :miss = ResourceStore.revalidate(key, %{"gen" => 1}, ~s("mine"))
    end

    test "an unusable identity is a miss rather than a crash" do
      assert :miss = ResourceStore.revalidate(nil, %{"gen" => 1}, ~s("mine"))
    end
  end

  describe "claim/3 under contention" do
    # "Exactly one" is the entire contract. Two sweep passes over one resource
    # both observing "not processed" and both publishing is the duplicate agent
    # wake this function exists to prevent, reappearing in the gap between a
    # read and a write.
    # The callers are started first and released together, because a read and a
    # write are only a handful of microseconds apart: tasks that merely start at
    # roughly the same time mostly miss the window and would let a check-then-act
    # implementation pass. Repeated over many keys so hitting it is not luck.
    test "grants exactly one winner however many callers race" do
      keys = 8400..8500
      callers = 8

      double_claimed =
        for id <- keys, reduce: [] do
          acc ->
            key = ResourceStore.key(:issue_comment, "owner", "repo", id)
            parent = self()

            tasks =
              for _caller <- 1..callers do
                Task.async(fn ->
                  send(parent, {:ready, self()})

                  receive do
                    :go -> ResourceStore.claim(key, :poll, "v1")
                  after
                    5_000 -> :never_released
                  end
                end)
              end

            for _task <- tasks, do: assert_receive({:ready, _pid}, 5_000)
            for task <- tasks, do: send(task.pid, :go)

            results = Enum.map(tasks, &Task.await(&1, 30_000))
            winners = Enum.count(results, &(&1 == :marked))

            if winners == 1, do: acc, else: [{id, winners} | acc]
        end

      assert double_claimed == [],
             "a claim was granted more than once; every extra winner publishes a duplicate and wakes an agent twice: " <>
               inspect(double_claimed)
    end

    test "a new version is a new claim, and again only one caller wins it" do
      key = ResourceStore.key(:issue_comment, "owner", "repo", 8401)
      assert :marked = ResourceStore.claim(key, :webhook, "v1")
      assert :already_processed = ResourceStore.claim(key, :poll, "v1")

      # The comment was edited. That is a different state of the same resource,
      # so it is claimable again — once.
      results =
        1..8
        |> Enum.map(fn _caller -> Task.async(fn -> ResourceStore.claim(key, :poll, "v2") end) end)
        |> Enum.map(&Task.await(&1, 30_000))

      assert Enum.count(results, &(&1 == :marked)) == 1
    end
  end

  describe "concurrent writers" do
    # Two writers share a key as soon as one pipe deposits a body and another
    # records a validator for the same resource, which is exactly what the
    # mutation write-through and agent read-through paths introduce on
    # `:pull_request` and `:issue`. A read-modify-write can then re-insert the
    # entry without the body it never saw while keeping the newer validator —
    # the bodyless pair every other path in this module refuses, produced by a
    # race. The watcher looks for that pair continuously rather than at the end,
    # because it is transient.
    test "an interleaved validator write never leaves a validator with no body" do
      key = ResourceStore.key(:pull_request, "owner", "repo", 8100)
      me = self()

      ResourceStore.put_resource(key, %{"n" => 0}, etag: "e0")

      watcher =
        spawn_link(fn ->
          watch = fn watch ->
            receive do
              :stop -> send(me, :stopped)
            after
              0 ->
                case :ets.lookup(ResourceStore.Table, key) do
                  [{^key, entry}] ->
                    if is_binary(Map.get(entry, :etag)) and is_nil(Map.get(entry, :data)) do
                      send(me, {:bodyless, Map.take(entry, [:etag, :data])})
                    else
                      watch.(watch)
                    end

                  _other ->
                    watch.(watch)
                end
            end
          end

          watch.(watch)
        end)

      1..8
      |> Enum.map(fn writer ->
        Task.async(fn ->
          for n <- 1..2_000 do
            if rem(writer, 2) == 0 do
              ResourceStore.put_resource(key, %{"n" => n}, etag: "body-#{writer}-#{n}")
            else
              ResourceStore.put_etag(key, "etag-#{writer}-#{n}")
            end
          end
        end)
      end)
      |> Enum.each(&Task.await(&1, 60_000))

      send(watcher, :stop)

      outcome =
        receive do
          {:bodyless, entry} -> {:bodyless, entry}
          :stopped -> :never_bodyless
        after
          10_000 -> :timeout
        end

      assert outcome == :never_bodyless, "a concurrent write lost the body and kept the validator: #{inspect(outcome)}"
      assert {:ok, %{data: data}} = ResourceStore.fetch(key)
      assert is_map(data)
    end
  end

  describe "merging into a held body" do
    # The write shape that loses data: read the held issue, change part of it,
    # put it back. Done as `fetch/1` then `put_resource/3` the window is an
    # entire round trip through the caller, and a probe with two writers
    # regressed the held body inside the first twenty writes — a webhook
    # delivery carrying the fresh object lands in the middle and the loser's
    # stale snapshot overwrites it. `"state"` is one of the fields that rolls
    # back, so a reader can be served `open` for a ticket Aiur has closed.
    #
    # Counting is the assertion, because it is exact: N atomic increments must
    # leave the counter at N. A lost update leaves it lower, always.
    test "concurrent merges lose nothing and the body never goes backwards" do
      key = ResourceStore.key(:issue, "owner", "repo", 8200)
      writers = 4
      per_writer = 150
      me = self()

      ResourceStore.put_resource(key, %{"gen" => 0, "state" => "open"}, version: "v0")

      sampler =
        spawn_link(fn ->
          watch = fn watch, highest ->
            receive do
              :stop -> send(me, :sampled)
            after
              0 ->
                case :ets.lookup(ResourceStore.Table, key) do
                  [{^key, %{data: %{"gen" => gen}}}] when gen < highest ->
                    send(me, {:regressed, highest, gen})

                  [{^key, %{data: %{"gen" => gen}}}] ->
                    watch.(watch, gen)

                  _other ->
                    watch.(watch, highest)
                end
            end
          end

          watch.(watch, 0)
        end)

      1..writers
      |> Enum.map(fn _writer ->
        Task.async(fn ->
          for _step <- 1..per_writer do
            ResourceStore.update_resource(
              key,
              fn held -> %{"gen" => Map.get(held || %{}, "gen", 0) + 1, "state" => "open"} end,
              source: :mutation
            )
          end
        end)
      end)
      |> Enum.each(&Task.await(&1, 60_000))

      send(sampler, :stop)

      assert_receive :sampled, 10_000

      refute_received {:regressed, _highest, _gen}

      assert ResourceStore.data(key) == %{"gen" => writers * per_writer, "state" => "open"},
             "every merge must survive; a lower count is a lost update"
    end

    test "a merge sees the held body and nil when there is none" do
      key = ResourceStore.key(:issue, "owner", "repo", 8201)

      assert :ok = ResourceStore.update_resource(key, fn held -> %{"seen" => held} end)
      assert ResourceStore.data(key) == %{"seen" => nil}

      assert :ok = ResourceStore.update_resource(key, fn held -> Map.put(held, "merged", true) end, version: "v1")

      assert ResourceStore.data(key) == %{"seen" => nil, "merged" => true}
      assert {:ok, %{version: "v1"}} = ResourceStore.fetch(key)
    end

    # The same refusals `put_resource/3` applies, applied to what the merge
    # returns rather than to what the caller passed.
    test "a merge that returns an unstorable body is refused with its validator" do
      key = ResourceStore.key(:issue, "owner", "repo", 8202)
      ResourceStore.put_resource(key, %{"kept" => true}, etag: ~s("old"))

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = ResourceStore.update_resource(key, fn _held -> %{atom: :keys} end, etag: ~s("new"))
      end)

      assert ResourceStore.fetch(key) == :miss
      assert ResourceStore.etag(key) == ~s("old")
    end

    test "a merge on a nil key is a no-op" do
      assert :ok = ResourceStore.update_resource(nil, fn _held -> %{"a" => 1} end)
    end
  end

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

  defp stop_store! do
    case Process.whereis(ResourceStore) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Supervisor.terminate_child(Aiur.Supervisor, ResourceStore)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          5_000 -> flunk("ResourceStore did not stop")
        end
    end
  end

  defp restart_store!(path) do
    stop_store!()
    Application.put_env(:aiur, :github_resource_store_path, path)
    {:ok, _pid} = Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
    :ok
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:aiur, :github_resource_store_path)

      case Process.whereis(ResourceStore) do
        nil -> Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
        _pid -> :ok
      end

      ResourceStore.reset()
    end)

    :ok
  end
end

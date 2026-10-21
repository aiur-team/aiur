defmodule Aiur.GitHub.ResourceStore.PersistenceTest do
  use Aiur.TestSupport
  use Aiur.ResourceStoreTestSupport

  alias Aiur.GitHub.ResourceStore

  describe "surviving restart" do
    # #2714: without it, every blocker record looks stale after a restart and
    # each held dependent pays one `blocked_by` read.
    test "full_body_at_ms survives the checkpoint", %{path: path} do
      key = ResourceStore.key(:issue, "owner", "repo", 5170)

      restart_store!(path)

      ResourceStore.put_resource(key, %{"number" => 5170, "state" => "open"}, source: :poll)
      {:ok, %{full_body_at_ms: stamped}} = ResourceStore.fetch(key)
      assert is_integer(stamped)
      assert :ok = ResourceStore.flush()

      restart_store!(path)

      assert {:ok, %{full_body_at_ms: ^stamped}} = ResourceStore.fetch(key)
    end

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

      assert ResourceStore.change_validator(etag_key) == ~s("survives")
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

      assert ResourceStore.change_validator(ResourceStore.key(:issue_comments, "owner", "repo", 79)) == ~s("kept")
      assert ResourceStore.size() == 1, "the unknown type must be dropped, not resurrected as a new atom"
      assert ResourceStore.change_validator({:not_a_real_type, "owner", "repo", "1"}) == nil
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

      assert ResourceStore.change_validator(ResourceStore.key(:issue_comments, "owner", "repo", 81)) == ~s("kept")
      assert ResourceStore.size() == 1, "a source atom must not decode into a resource key"
    end

    # The retention window is a number nothing pinned: every ageing test used
    # 73 hours, so shortening the window to 25 hours left the whole suite green
    # while silently throwing away two days of held bodies. These two bracket it
    # — one entry an hour inside the window and one an hour outside — so the
    # constant can only change by failing a test.
    #
    # Every fixture here carries a `version`. Only a versioned mark earns the
    # full retention window: an unversioned one suppresses on identity alone and
    # is deliberately cut short by `unversioned_suppression_ms/0`, so a fixture
    # without one expires after 30 minutes and says nothing whatsoever about
    # `@retention_ms`.
    test "the retention window keeps an entry an hour inside it", %{path: path} do
      inside_ms = System.system_time(:millisecond) - (72 * 60 * 60 * 1000 - 60 * 60 * 1000)

      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "entries" => %{
            "issue_comment|owner|repo|5160" => %{
              "processed_at_ms" => inside_ms,
              "recorded_at_ms" => inside_ms,
              "version" => "2026-08-14T00:00:00Z"
            }
          }
        })
      )

      restart_store!(path)

      assert ResourceStore.processed?(
               ResourceStore.key(:issue_comment, "owner", "repo", 5160),
               "2026-08-14T00:00:00Z"
             ),
             "an entry inside the 72h retention window must survive a restart"
    end

    test "the retention window drops an entry an hour outside it", %{path: path} do
      outside_ms = System.system_time(:millisecond) - (72 * 60 * 60 * 1000 + 60 * 60 * 1000)

      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "entries" => %{
            "issue_comment|owner|repo|5161" => %{
              "processed_at_ms" => outside_ms,
              "recorded_at_ms" => outside_ms,
              "version" => "2026-08-14T00:00:00Z"
            }
          }
        })
      )

      restart_store!(path)

      refute ResourceStore.processed?(
               ResourceStore.key(:issue_comment, "owner", "repo", 5161),
               "2026-08-14T00:00:00Z"
             )
    end

    # Carries a version for the same reason as the two above. Without one this
    # refute became unfailable the moment the suppression bound landed: an
    # unversioned mark cannot be `processed?` past 30 minutes whatever the
    # retention window is, so no change to `@retention_ms` could ever turn it
    # red.
    test "entries older than the retention window are not reloaded", %{path: path} do
      stale_ms = System.system_time(:millisecond) - 73 * 60 * 60 * 1000

      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "entries" => %{
            "issue_comment|owner|repo|5152" => %{
              "processed_at_ms" => stale_ms,
              "recorded_at_ms" => stale_ms,
              "version" => "2026-08-14T00:00:00Z"
            }
          }
        })
      )

      restart_store!(path)

      refute ResourceStore.processed?(
               ResourceStore.key(:issue_comment, "owner", "repo", 5152),
               "2026-08-14T00:00:00Z"
             )
    end

    # The boot filter must agree with the sweep and with `fetch/1` about what is
    # outdated. The trap this pins: `recorded_at_ms` is refreshed by every write,
    # so a body past retention whose entry was re-touched would reload from disk
    # and survive the next checkpoint too. The reload must not resurrect the
    # unservable body — but it must not throw away the entry either, because the
    # processed mark on it is the only thing that stops a duplicate dispatch
    # right after a restart. So the entry reloads *without* its body: `data` is
    # gone, `processed?` still answers. A fresh body is asserted present, so an
    # over-aggressive filter fails the test too.
    test "an expired body reloads without its body when recorded_at is fresh", %{path: path} do
      now = System.system_time(:millisecond)
      body_ms = now - 73 * 60 * 60 * 1000

      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "entries" => %{
            "issue|owner|repo|5155" => %{
              "data" => %{"number" => 5155},
              "data_version" => "2026-08-14T00:00:00Z",
              "fetched_at_ms" => body_ms,
              "recorded_at_ms" => now,
              "processed_at_ms" => now - 1000,
              "version" => "2026-08-14T00:00:00Z"
            },
            "issue|owner|repo|5156" => %{
              "data" => %{"number" => 5156},
              "data_version" => "2026-08-14T00:00:00Z",
              "fetched_at_ms" => now - 1000,
              "recorded_at_ms" => now
            }
          }
        })
      )

      restart_store!(path)

      key = ResourceStore.key(:issue, "owner", "repo", 5155)

      # Asserted on the entry, not through `data/1`/`fetch/1`: both readers
      # declined an expired body on main already, so only the entry itself can
      # prove the body did not reload.
      assert [{^key, kept}] = :ets.lookup(ResourceStore.Table, key),
             "the entry must survive the restart; only the body goes"

      refute Map.has_key?(kept, :data),
             "an expired body must not survive a restart on the strength of a fresh recorded_at"

      refute Map.has_key?(kept, :data_version),
             "the body's version must not survive the restart either"

      assert ResourceStore.processed?(key, "2026-08-14T00:00:00Z"),
             "the processed mark on the entry must survive the restart"

      assert ResourceStore.fetch(ResourceStore.key(:issue, "owner", "repo", 5156)) != :miss,
             "a body inside the retention window must still reload"
    end

    # The nil edge of the same agreement. `fetch/1` reads a body with no
    # `fetched_at_ms` as expired (`nil` is treated as the epoch, long past the
    # window), so a boot filter that reloaded such a body would hold one the
    # read can never serve — "stale" forever, at the one age no record exists
    # for. A corrupt or hand-written checkpoint is exactly where this lands: the
    # body is dropped, and the entry's mark — if it has one — is the only thing
    # a restart keeps.
    test "a body with no fetched_at_ms reloads without its body", %{path: path} do
      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "entries" => %{
            "issue|owner|repo|5157" => %{
              "data" => %{"number" => 5157},
              "data_version" => "2026-08-14T00:00:00Z",
              "recorded_at_ms" => System.system_time(:millisecond)
            }
          }
        })
      )

      restart_store!(path)

      key = ResourceStore.key(:issue, "owner", "repo", 5157)

      # Asserted on the entry, not through `data/1`/`fetch/1`: the readers
      # already decline a body with no `fetched_at_ms` on main, so only the
      # entry can prove the boot filter dropped it.
      assert [{^key, kept}] = :ets.lookup(ResourceStore.Table, key),
             "the entry must survive the restart; only the body goes"

      refute Map.has_key?(kept, :data),
             "a body with no fetched_at_ms must be dropped at boot, matching fetch/1's decline"

      refute Map.has_key?(kept, :data_version),
             "the body's version must not survive the restart either"
    end

    # The other half of the boot filter's decision: an entry whose
    # `recorded_at_ms` is itself past cutoff has had no write in the whole
    # window, so *nothing* in it is in use any more — the whole entry is
    # skipped, body and mark together. Nothing before this rework covered this
    # direction, which is why the `:skip` mutant survived.
    test "an entry whose recorded_at is itself past cutoff is not resurrected at boot", %{path: path} do
      now = System.system_time(:millisecond)

      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "entries" => %{
            "issue|owner|repo|5158" => %{
              "data" => %{"number" => 5158},
              "data_version" => "2026-08-14T00:00:00Z",
              "fetched_at_ms" => now,
              "recorded_at_ms" => now - 73 * 60 * 60 * 1000,
              "processed_at_ms" => now - 73 * 60 * 60 * 1000,
              "version" => "2026-08-14T00:00:00Z"
            }
          }
        })
      )

      restart_store!(path)

      key = ResourceStore.key(:issue, "owner", "repo", 5158)

      assert :ets.lookup(ResourceStore.Table, key) == [],
             "a whole entry whose recorded_at is itself past cutoff must not be resurrected at boot"
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
end

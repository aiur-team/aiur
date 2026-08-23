defmodule Aiur.GitHub.ResourceStoreTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{ResourceFetch, ResourceStore}

  setup do
    dir = Aiur.TestSupport.tmp_root!("aiur-resource-store")
    File.mkdir_p!(dir)
    path = Path.join(dir, "github_resources.json")

    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, path: path, dir: dir}
  end

  describe "resource identity" do
    test "selection snapshots are restart-durable resource identities" do
      assert ResourceStore.key(:pr_review_threads, "owner", "repo", 77) ==
               {:pr_review_threads, "owner", "repo", "77"}

      assert ResourceStore.key(:ci_contexts, "owner", "repo", 42) ==
               {:ci_contexts, "owner", "repo", "42"}
    end

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
    test "stores and returns a validator alongside the body it validates" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 42)

      assert ResourceStore.etag(key) == nil
      assert :ok = ResourceStore.put_resource(key, %{"a" => 1}, etag: ~s("abc123"))
      assert ResourceStore.etag(key) == ~s("abc123")
    end

    # `etag/1` is the accessor for a reader that wants the *body*, so it answers
    # only when the body is there. A validator recorded on its own can only earn
    # that reader a `304` and no data — a spent request, then a second
    # unconditional one. Two requests where one was needed.
    test "a validator recorded without a body is not offered to a reader of bodies" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 45)

      assert :ok = ResourceStore.put_etag(key, ~s("abc123"))

      assert ResourceStore.etag(key) == nil
      assert ResourceStore.change_validator(key) == ~s("abc123")
    end

    # The one honest use of a bodyless validator: a reader that only wants to
    # know whether something changed. It asks for it by name.
    test "change_validator answers with or without a body, and honours retention" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 46)
      ResourceStore.put_resource(key, %{"a" => 1}, etag: ~s("v1"))

      assert ResourceStore.change_validator(key) == ~s("v1")

      [{^key, entry}] = :ets.lookup(ResourceStore.Table, key)
      aged = Map.put(entry, :recorded_at_ms, System.system_time(:millisecond) - 73 * 60 * 60 * 1000)
      :ets.insert(ResourceStore.Table, {key, aged})

      assert ResourceStore.change_validator(key) == nil
    end

    test "an absent validator is never invented" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 43)

      ResourceStore.put_etag(key, nil)
      ResourceStore.put_etag(key, "")

      assert ResourceStore.etag(key) == nil
      assert ResourceStore.change_validator(key) == nil
    end

    test "a validator and a processed mark coexist on one resource" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 44)

      ResourceStore.put_etag(key, ~s("v1"))
      ResourceStore.mark_processed(key, :poll)

      assert ResourceStore.change_validator(key) == ~s("v1")
      assert ResourceStore.processed?(key)
    end
  end

  # `etag: :derive` is the writer's answer to "I have no validator of my own" —
  # a webhook delivery is exactly that writer (#2126). The store derives a
  # content-based validator from the body being deposited, keeps a held validator
  # when the body is unchanged, and never leaves "body, no validator" behind —
  # the state in which `etag/1` answers nothing and every strict read pays full
  # price instead of a free `304`.
  describe ":derive — a validator derived from the deposited body" do
    test "a first deposit derives a validator from the body" do
      key = ResourceStore.key(:issue, "owner", "repo", 8600)

      assert :ok = ResourceStore.put_resource(key, %{"state" => "open"}, source: :webhook, version: "v1", etag: :derive)

      assert {:ok, %{data: %{"state" => "open"}, etag: etag}} = ResourceStore.fetch(key)
      assert is_binary(etag) and etag != ""
    end

    test "an unchanged body keeps the held validator" do
      key = ResourceStore.key(:issue, "owner", "repo", 8601)
      ResourceStore.put_resource(key, %{"state" => "open"}, etag: ~s("github-real"))

      ResourceStore.put_resource(key, %{"state" => "open"}, source: :webhook, version: "v1", etag: :derive)

      assert ResourceStore.etag(key) == ~s("github-real"),
             "a re-deposit of the same body must not knock out a GitHub ETag a fetch recorded"
    end

    test "a changed body re-derives a validator that describes it" do
      key = ResourceStore.key(:issue, "owner", "repo", 8602)
      ResourceStore.put_resource(key, %{"state" => "open"}, source: :webhook, version: "v1", etag: :derive)
      {:ok, %{etag: before}} = ResourceStore.fetch(key)

      ResourceStore.put_resource(key, %{"state" => "closed"}, source: :webhook, version: "v2", etag: :derive)

      assert {:ok, %{data: %{"state" => "closed"}, etag: later}} = ResourceStore.fetch(key)
      assert is_binary(later) and later != ""
      assert later != before, "a validator describing a different body is a stale one"
    end

    test "a nil body derives nothing" do
      key = ResourceStore.key(:issue, "owner", "repo", 8603)
      ResourceStore.put_resource(key, %{"state" => "open"}, source: :webhook, version: "v1", etag: :derive)

      ResourceStore.put_resource(key, nil, source: :webhook, version: "v2", etag: :derive)

      # A nil body is not a body, so it earns no validator — and a reader of
      # bodies is not offered the one left behind.
      assert ResourceStore.fetch(key) == :miss
      assert ResourceStore.etag(key) == nil
    end
  end

  # The finding this closes: `etag/1` had no retention check at all while
  # `fetch/1` had one, so past 72 hours the store handed out a validator for a
  # body it had already stopped serving. A caller reading it raw — U4's issue
  # revalidation did exactly that — was guaranteed a `304` with nothing behind
  # it and had to read again unconditionally.
  describe "a validator is never offered without the body it validates" do
    test "an expired body takes its validator out of the reader's reach" do
      key = ResourceStore.key(:issue, "owner", "repo", 8400)
      ResourceStore.put_resource(key, %{"state" => "open"}, etag: ~s("v1"))

      [{^key, entry}] = :ets.lookup(ResourceStore.Table, key)
      aged = Map.put(entry, :fetched_at_ms, System.system_time(:millisecond) - 73 * 60 * 60 * 1000)
      :ets.insert(ResourceStore.Table, {key, aged})

      assert ResourceStore.fetch(key) == :miss
      assert ResourceStore.etag(key) == nil, "a validator for a body the store will not serve is two requests, not one"
    end

    test "dropping the body takes the validator out of the reader's reach too" do
      key = ResourceStore.key(:issue, "owner", "repo", 8401)
      ResourceStore.put_resource(key, %{"state" => "open"}, etag: ~s("v1"))

      ResourceStore.drop_data(key)

      assert ResourceStore.etag(key) == nil
      assert ResourceStore.change_validator(key) == ~s("v1"), "change detection survives, by name"
    end

    # `drop_etag/1` exists for the reader that sent `If-None-Match` for a key the
    # store holds no body for, was answered `304`, and got nothing. That reader's
    # entry is *by definition* bodyless — so a `drop_etag/1` that decided whether
    # to act by asking `etag/1`, which deliberately answers only when a body is
    # held, was a no-op in the one state it is for, and the same empty `304`
    # repeated every cycle for the whole retention window.
    test "forgetting a validator works in the bodyless state it exists for" do
      key = ResourceStore.key(:issue, "owner", "repo", 8402)
      ResourceStore.put_etag(key, ~s("v1"))

      assert ResourceStore.change_validator(key) == ~s("v1")
      assert ResourceStore.etag(key) == nil, "there is no body, so no reader of bodies is offered it"

      assert :ok = ResourceStore.drop_etag(key)

      assert ResourceStore.change_validator(key) == nil,
             "a validator the caller was told had been forgotten must actually be gone"
    end

    test "forgetting a validator nothing holds creates no entry" do
      key = ResourceStore.key(:issue, "owner", "repo", 8403)

      assert :ok = ResourceStore.drop_etag(key)
      assert :ets.lookup(ResourceStore.Table, key) == []
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
    #
    # The sampler **keeps watching after it sees a regression** and reports the
    # sequence it observed at the end. An earlier version stopped recursing on the
    # first sighting, so every failure surfaced as a bare 10-second
    # `assert_receive` timeout and the two assertions that tell the two defects
    # apart — a true lost update, where the final count is short, against a
    # transient rollback, where it is not — never ran. A probe that detects a race
    # but cannot describe it costs more time than it saves.
    #
    # The writers are also released from a barrier rather than merely started
    # together: a read and its swap are microseconds apart, so `Task.async`'s own
    # start-up skew is wide enough to miss the window entirely.
    test "concurrent merges lose nothing and the body never goes backwards" do
      key = ResourceStore.key(:issue, "owner", "repo", 8200)
      writers = 8
      per_writer = 200
      me = self()

      ResourceStore.put_resource(key, %{"gen" => 0, "state" => "open"}, version: "v0")

      sampler =
        spawn_link(fn ->
          watch = fn watch, highest, backwards ->
            receive do
              :stop -> send(me, {:sampled, Enum.reverse(backwards)})
            after
              0 ->
                case :ets.lookup(ResourceStore.Table, key) do
                  [{^key, %{data: %{"gen" => gen}}}] when gen < highest ->
                    watch.(watch, highest, record_backwards(backwards, {highest, gen}))

                  [{^key, %{data: %{"gen" => gen}}}] ->
                    watch.(watch, gen, backwards)

                  _other ->
                    watch.(watch, highest, backwards)
                end
            end
          end

          watch.(watch, 0, [])
        end)

      barrier = :atomics.new(1, [])

      tasks =
        for _writer <- 1..writers do
          Task.async(fn ->
            spin = fn spin -> if :atomics.get(barrier, 1) == 0, do: spin.(spin), else: :ok end
            spin.(spin)

            for _step <- 1..per_writer do
              ResourceStore.update_resource(
                key,
                fn held -> %{"gen" => Map.get(held || %{}, "gen", 0) + 1, "state" => "open"} end,
                source: :mutation
              )
            end
          end)
        end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :atomics.put(barrier, 1, 1)
          Enum.each(tasks, &Task.await(&1, 60_000))
        end)

      send(sampler, :stop)

      assert_receive {:sampled, backwards}, 10_000

      final = ResourceStore.data(key)

      assert backwards == [],
             "the held body went backwards: #{inspect(backwards)} (as {highest_seen, then_observed}); final body #{inspect(final)}"

      assert final == %{"gen" => writers * per_writer, "state" => "open"},
             "every merge must survive; a lower count is a lost update. observed backwards steps: #{inspect(backwards)}"

      # A write the compare-and-swap could not land must be abandoned, never
      # forced: forcing it deposits a body derived from a read the table has long
      # moved past, which is the rollback above with the swap bypassed. Asserted
      # on the log because it is the only externally visible trace of the
      # exhaustion path, and because the sampler can miss the single instant the
      # forced write is observable.
      refute log =~ "abandoned a contended write",
             "the compare-and-swap ran out of budget under ordinary contention; it must resolve within it"
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
    # returns rather than to what the caller passed — including leaving the held
    # body where it is.
    test "a merge that returns an unstorable body leaves the held body alone" do
      key = ResourceStore.key(:issue, "owner", "repo", 8202)
      ResourceStore.put_resource(key, %{"kept" => true}, etag: ~s("old"))

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = ResourceStore.update_resource(key, fn _held -> %{atom: :keys} end, etag: ~s("new"))
      end)

      assert ResourceStore.data(key) == %{"kept" => true}
      assert ResourceStore.etag(key) == ~s("old")
    end

    test "a merge on a nil key is a no-op" do
      assert :ok = ResourceStore.update_resource(nil, fn _held -> %{"a" => 1} end)
    end

    # A writer whose deposit is conditional on what is held has to make that
    # decision where the answer is still true. Deciding outside the call and
    # depositing afterwards is a check-then-act with a whole round trip in the
    # middle, and the newer body that lands in the middle is what the older
    # delivery then overwrites.
    test "a merge can decline the write from inside the swap" do
      key = ResourceStore.key(:issue, "owner", "repo", 8203)
      ResourceStore.put_resource(key, %{"gen" => 2, "state" => "closed"}, version: "v2", etag: ~s("v2"))

      assert :unchanged =
               ResourceStore.update_resource(key, fn _held, %{version: held} ->
                 if held == "v2", do: :unchanged, else: %{"gen" => 1, "state" => "open"}
               end)

      assert ResourceStore.data(key) == %{"gen" => 2, "state" => "closed"},
             "a declined merge writes nothing at all"

      assert {:ok, %{version: "v2", etag: ~s("v2")}} = ResourceStore.fetch(key)
    end

    test "a declined merge on a key nothing holds creates no entry" do
      key = ResourceStore.key(:issue, "owner", "repo", 8204)

      assert :unchanged = ResourceStore.update_resource(key, fn _held, _meta -> :unchanged end)
      assert :ets.lookup(ResourceStore.Table, key) == []
    end

    test "a two-arity merge is handed what the entry says about the held body" do
      key = ResourceStore.key(:issue, "owner", "repo", 8205)
      ResourceStore.put_resource(key, %{"gen" => 1}, version: "v1", etag: ~s("e1"))

      assert :ok =
               ResourceStore.update_resource(
                 key,
                 fn held, meta -> Map.merge(held, %{"saw_version" => meta.version, "saw_etag" => meta.etag}) end,
                 version: "v2"
               )

      assert ResourceStore.data(key) == %{"gen" => 1, "saw_version" => "v1", "saw_etag" => ~s("e1")}
    end

    # A version supplied from outside describes a body the merge may not produce:
    # under contention the merge re-runs against whatever won, and the marker
    # computed beforehand then labels the winner's content with the loser's
    # version. Nothing raises — the body is just marked older than it is, and the
    # next genuinely stale delivery is accepted against that wrong marker.
    test "a version function is applied to the body that actually won the swap" do
      key = ResourceStore.key(:issue, "owner", "repo", 8500)
      writers = 4
      per_writer = 100

      ResourceStore.put_resource(key, %{"gen" => 0, "updated_at" => "v0"}, version: "v0")

      1..writers
      |> Enum.map(fn _writer ->
        Task.async(fn ->
          for _step <- 1..per_writer do
            ResourceStore.update_resource(
              key,
              fn held ->
                gen = Map.get(held || %{}, "gen", 0) + 1
                %{"gen" => gen, "updated_at" => "v#{gen}"}
              end,
              version: fn body -> body["updated_at"] end
            )
          end
        end)
      end)
      |> Enum.each(&Task.await(&1, 60_000))

      assert {:ok, %{data: %{"gen" => gen, "updated_at" => marker}, version: version}} = ResourceStore.fetch(key)
      assert gen == writers * per_writer
      assert version == marker, "the stored marker must describe the stored body, not a losing read's"
    end

    test "a binary version still describes the deposit exactly as before" do
      key = ResourceStore.key(:issue, "owner", "repo", 8501)

      ResourceStore.update_resource(key, fn _held -> %{"a" => 1} end, version: "v7")

      assert {:ok, %{version: "v7"}} = ResourceStore.fetch(key)
    end

    test "a version function answering nil records version unknown" do
      key = ResourceStore.key(:issue, "owner", "repo", 8502)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          ResourceStore.update_resource(key, fn _held -> %{"a" => 1} end, version: fn body -> body["missing"] end)
        end)

      assert {:ok, %{version: nil}} = ResourceStore.fetch(key)
      assert log =~ "no version"
    end
  end

  # A `nil` version is worse than a missing one: `GitHubWebhook.Deposit`'s
  # regression guard needs a binary marker on both sides, so one version-less
  # deposit does not weaken the guard for that resource, it switches it off and
  # every later out-of-order delivery lands. Silent at every level until someone
  # finds it by accident, so the store says it.
  describe "a body stored without a version" do
    test "is loud for an identity where ordering decides correctness" do
      key = ResourceStore.key(:issue, "owner", "repo", 8510)

      log = ExUnit.CaptureLog.capture_log(fn -> ResourceStore.put_resource(key, %{"state" => "open"}) end)

      assert log =~ "with no version"
      assert log =~ "late delivery"
    end

    test "is quiet for an endpoint list, which has no marker of its own" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 8511)

      log = ExUnit.CaptureLog.capture_log(fn -> ResourceStore.put_resource(key, [%{"id" => 1}]) end)

      refute log =~ "with no version"
    end

    test "is quiet when a version is supplied" do
      key = ResourceStore.key(:issue, "owner", "repo", 8512)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          ResourceStore.put_resource(key, %{"state" => "open"}, version: "2026-08-17T12:00:00Z")
        end)

      refute log =~ "with no version"
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

    # The hard backstop. Asserted as "evicts down to exactly the ceiling", which
    # fails both ways: a lower ceiling leaves fewer entries, a higher one leaves
    # the overflow in place.
    test "the entry ceiling evicts the oldest down to exactly its limit" do
      ResourceStore.reset()
      now = System.system_time(:millisecond)
      store = Process.whereis(ResourceStore)

      rows =
        for index <- 1..100_001 do
          {{:issue, "owner", "repo", Integer.to_string(index)}, %{recorded_at_ms: now - (100_001 - index)}}
        end

      :ets.insert(ResourceStore.Table, rows)
      assert ResourceStore.size() == 100_001

      send(store, :sweep)
      # `:sys.get_state/1` returns only after every earlier message is handled,
      # so the sweep has finished by the time it answers.
      _state = :sys.get_state(store)

      assert ResourceStore.size() == 100_000
      assert :ets.lookup(ResourceStore.Table, {:issue, "owner", "repo", "1"}) == []
      assert [_kept] = :ets.lookup(ResourceStore.Table, {:issue, "owner", "repo", "2"})
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

  # Backdates a suppression mark's own timestamp, leaving the entry otherwise
  # untouched, so the ageing path under test is the real one.
  defp age_mark!(key, by_ms) do
    [{^key, entry}] = :ets.lookup(ResourceStore.Table, key)
    :ets.insert(ResourceStore.Table, {key, Map.update!(entry, :processed_at_ms, &(&1 - by_ms))})
    :ok
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

  # Bounded and de-duplicated: the rollback sampler spins, so one rollback is
  # otherwise observed thousands of times and the report it produces is
  # unreadable. Keeping the sequence is the point — the shape of the backwards
  # steps is what names the mechanism.
  defp record_backwards([pair | _rest] = backwards, pair), do: backwards
  defp record_backwards(backwards, _pair) when length(backwards) >= 8, do: backwards
  defp record_backwards(backwards, pair), do: [pair | backwards]
end

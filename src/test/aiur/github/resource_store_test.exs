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

    test "an oversized body is refused, and refusing keeps the validator" do
      key = ResourceStore.key(:issue_comments, "owner", "repo", 9)
      ResourceStore.put_resource(key, %{"small" => true}, etag: "W/\"old\"")

      huge = %{"blob" => String.duplicate("x", 300 * 1024)}
      ResourceStore.put_resource(key, huge, etag: "W/\"new\"")

      assert ResourceStore.fetch(key) == :miss, "an oversized body is refused, not stored"
      assert ResourceStore.etag(key) == "W/\"new\"", "change detection is still worth keeping"
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

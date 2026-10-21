defmodule Aiur.GitHub.ResourceStore.MergeTest do
  use Aiur.TestSupport
  use Aiur.ResourceStoreTestSupport

  alias Aiur.GitHub.ResourceStore

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
    # `assert_receive` timeout and the two assertions that tell the two defects, 1000
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
end

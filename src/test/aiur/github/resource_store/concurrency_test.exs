defmodule Aiur.GitHub.ResourceStore.ConcurrencyTest do
  use Aiur.TestSupport
  use Aiur.ResourceStoreTestSupport

  alias Aiur.GitHub.ResourceStore

  describe "revalidate/3" do
    # #2714: the dispatch gate judges a blocker's `"state"` by this clock, so a
    # `304` that proves the whole body current must move it.
    test "a confirmation moves full_body_at_ms" do
      key = ResourceStore.key(:issue, "owner", "repo", 8301)
      body = %{"number" => 8301, "state" => "open"}
      ResourceStore.put_resource(key, body, source: :poll)
      {:ok, before} = ResourceStore.fetch(key)
      Process.sleep(2)

      assert :confirmed = ResourceStore.revalidate(key, body, ~s("e8301"))

      {:ok, entry} = ResourceStore.fetch(key)
      assert entry.full_body_at_ms > before.full_body_at_ms
    end

    test "a partial write moves fetched_at_ms but not full_body_at_ms" do
      key = ResourceStore.key(:issue, "owner", "repo", 8302)
      ResourceStore.put_resource(key, %{"number" => 8302, "state" => "open", "labels" => []}, source: :poll)
      {:ok, before} = ResourceStore.fetch(key)
      Process.sleep(2)

      ResourceStore.update_resource(key, &Map.put(&1, "labels", [%{"name" => "x"}]), partial: true)

      {:ok, entry} = ResourceStore.fetch(key)
      assert entry.data["labels"] == [%{"name" => "x"}]
      assert entry.fetched_at_ms > before.fetched_at_ms
      assert entry.full_body_at_ms == before.full_body_at_ms
    end

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
end

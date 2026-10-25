defmodule Aiur.BuildOrder.SharedResourceStoreOrderingTest do
  @moduledoc """
  The shared GitHub read under contention and outage: a newer body is never
  overwritten by an older read, and a missing store fails open. Split from
  `SharedResourceStoreTest`.
  """

  use Aiur.TestSupport

  import Aiur.BuildOrder.SharedResourceStoreSupport

  alias Aiur.GitHub.Issues
  alias Aiur.GitHub.ResourceStore

  @repository {"owner", "repo"}
  # The staleness a reader states it can accept. There is no default: a caller
  # that says nothing gets a conditional request rather than an arbitrarily old
  # body, which is the "never a silent guess" half of R7 and is pinned below.
  @tolerance_ms 30_000

  setup do
    {:ok, requests: prepare_shared_store()}
  end

  # A read and a webhook delivery race for the same key. The read's round trip is
  # long, so "I fetched it" is routinely older news than "it just changed", and a
  # write that ignores that does not merely hold a stale body — it stamps
  # `fetched_at_ms` with now, so the stale body is described as freshly fetched
  # and a reader asking for something recent is handed state from before the
  # change.
  describe "a newer body is never overwritten by an older read" do
    test "a full read older than the held version is refused" do
      key = ResourceStore.key(:issue, "owner", "repo", "7")

      # A delivery lands first, carrying the newer object.
      newer = Map.put(issue_body(7), "updated_at", "2026-01-09T00:00:00Z")
      ResourceStore.put_resource(key, newer, source: :webhook, version: "2026-01-09T00:00:00Z")

      # A read that was already in flight returns the older object.
      recorder = start_recorder()
      older = Map.put(issue_body(7), "updated_at", "2026-01-02T00:00:00Z")

      request_fun =
        recording_fun(recorder, fn _request ->
          {:ok, %{status: 200, headers: [{"etag", "\"v1\""}], body: older}}
        end)

      assert {:ok, _body, :fetched} =
               Issues.fetch_issue_raw_conditional(7,
                 repository: @repository,
                 request_fun: request_fun,
                 revalidate: true
               )

      # The caller still gets what it fetched — refusing the deposit is not
      # refusing the read — but the store keeps the newer object.
      assert {:ok, %{data: held, version: "2026-01-09T00:00:00Z"}} = ResourceStore.fetch(key)
      assert held == newer
    end

    # The `304` path is a read-then-write pair, so it has the same hazard with a
    # narrower window: it re-deposits the body it just read in order to move the
    # freshness clock. A delivery landing in between must survive.
    test "refreshing a validated body does not clobber a newer one" do
      key = ResourceStore.key(:issue, "owner", "repo", "7")
      older = Map.put(issue_body(7), "updated_at", "2026-01-02T00:00:00Z")
      newer = Map.put(issue_body(7), "updated_at", "2026-01-09T00:00:00Z")

      recorder = start_recorder()

      request_fun =
        recording_fun(recorder, fn request ->
          case Map.get(request, :etag) do
            nil -> {:ok, %{status: 200, headers: [{"etag", "\"v1\""}], body: older}}
            "\"v1\"" -> {:ok, %{status: 304, headers: [{"etag", "\"v1\""}]}}
          end
        end)

      base = [repository: @repository, request_fun: request_fun]
      assert {:ok, _body, :fetched} = Issues.fetch_issue_raw_conditional(7, base)

      # The delivery lands between the read and its revalidation, carrying the
      # validator the held body was fetched under. That is what keeps this case
      # about the `304` path: a delivery that deposits a *different* body with no
      # validator of its own discards the held one — a validator may never sit
      # beside a body it does not describe — and the revalidation would then be an
      # unconditional read rather than the read-then-write pair under test.
      ResourceStore.put_resource(key, newer,
        source: :webhook,
        version: "2026-01-09T00:00:00Z",
        etag: "\"v1\""
      )

      assert {:ok, _body, :not_modified} =
               Issues.fetch_issue_raw_conditional(7, base ++ [revalidate: true])

      assert {:ok, %{data: held, version: "2026-01-09T00:00:00Z"}} = ResourceStore.fetch(key)
      assert held == newer
    end

    # The two tests above can only observe the outcome, not the window: the body a
    # `304` re-deposits is read microseconds earlier, so a single-threaded test
    # cannot get between the read and the write. This one does it the only way that
    # actually proves anything — concurrently, the way the store's own authors
    # demonstrated that `fetch/1` + `put_resource/3` "regressed the held body
    # within the first twenty writes".
    #
    # The invariant is not "the newest write wins" — that is a race by
    # construction. It is that the entry is never *incoherent*: the held body's
    # own `updated_at` must always be the held `version`, and the version must
    # never go backwards. A clobber breaks exactly that pairing, by stamping one
    # writer's version onto another writer's body.
    test "concurrent deliveries and clock refreshes never leave a mismatched entry" do
      key = ResourceStore.key(:issue, "owner", "repo", "7")
      versions = Enum.map(1..40, &"2026-01-01T00:00:#{String.pad_leading(to_string(&1), 2, "0")}Z")

      body_for = fn version ->
        Map.merge(issue_body(7), %{"updated_at" => version, "title" => version})
      end

      [seed | _rest] = versions
      ResourceStore.put_resource(key, body_for.(seed), source: :webhook, version: seed, etag: "\"v1\"")

      request_fun = fn _request -> {:ok, %{status: 304, headers: [{"etag", "\"v1\""}]}} end
      opts = [repository: @repository, request_fun: request_fun, revalidate: true]

      deliveries =
        for version <- versions do
          Task.async(fn ->
            ResourceStore.put_resource(key, body_for.(version), source: :webhook, version: version)
          end)
        end

      refreshes = for _ <- 1..40, do: Task.async(fn -> Issues.fetch_issue_raw_conditional(7, opts) end)

      Task.await_many(deliveries ++ refreshes, 10_000)

      assert {:ok, %{data: held, version: version}} = ResourceStore.fetch(key)

      # The body and the version it is filed under must describe the same object.
      assert held["updated_at"] == version
      assert held["title"] == version

      # The winner is deliberately not asserted: forty deliveries racing each other
      # have no defined order, so "the newest wins" would be a flake dressed as a
      # guarantee. What is guaranteed is that the entry holds *some* object that
      # was really deposited, whole.
      assert version in versions
    end
  end

  describe "failing open" do
    # R11: store unavailable means behave exactly as before the store existed.
    # The store is genuinely stopped, not merely emptied — `reset/0` leaves the
    # ETS table and the owning process alive, so it proves a cache miss and says
    # nothing about a store that is down. Those are different code paths:
    # `with_table/2`'s `:undefined` branch is only reached when the table is gone.
    test "with no store running the read is unconditional, exactly as before" do
      recorder = start_recorder()
      request_fun = recording_fun(recorder, fn _request -> ok_issue(7) end)
      opts = [repository: @repository, request_fun: request_fun, freshness_ms: @tolerance_ms]

      assert {:ok, _body, :fetched} = Issues.fetch_issue_raw_conditional(7, opts)

      # Held now, so a second read inside the window would normally cost nothing.
      # Everything below is therefore attributable to the store being gone.
      assert count(recorder) == 1

      stop_store!()

      assert {:ok, _body, :fetched} = Issues.fetch_issue_raw_conditional(7, opts)
      assert {:ok, _body, :fetched} = Issues.fetch_issue_raw_conditional(7, opts)

      # Every read pays, and none of them raises into the caller: degrade, never
      # fail. A conditional request is impossible too — there is no validator to
      # send, so this must be the unconditional pre-store shape.
      assert count(recorder) == 3
      assert Enum.all?(requests(recorder), &(not Map.has_key?(&1, :etag)))
    end

    # A cache miss is not a stopped store, and the case above no longer proves
    # both. This is the miss, kept separately so neither can stand in for the
    # other.
    test "an empty store misses and fetches without a validator" do
      recorder = start_recorder()
      request_fun = recording_fun(recorder, fn _request -> ok_issue(7) end)
      opts = [repository: @repository, request_fun: request_fun, freshness_ms: @tolerance_ms]

      assert {:ok, _body, :fetched} = Issues.fetch_issue_raw_conditional(7, opts)

      ResourceStore.reset()

      assert {:ok, _body, :fetched} = Issues.fetch_issue_raw_conditional(7, opts)
      assert count(recorder) == 2
    end
  end
end

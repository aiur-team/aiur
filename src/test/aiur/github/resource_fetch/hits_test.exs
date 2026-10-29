defmodule Aiur.GitHub.ResourceFetch.HitsTest do
  @moduledoc """
  Every assertion here is a **call count** or the presence of an upstream call,
  never a latency and never a percentage. "Free" means the fetcher was invoked
  zero times, or invoked and answered `304`.
  """

  use Aiur.TestSupport
  import Aiur.ResourceFetchTestSupport

  alias Aiur.GitHub.{ResourceFetch, ResourceStore}

  setup do
    ResourceStore.reset()
    on_exit(fn -> ResourceStore.reset() end)
    :ok
  end

  describe "stating a tolerance is mandatory" do
    test "a call with no declared freshness is refused" do
      key = key(1)

      assert_raise ArgumentError, ~r/requires :freshness/, fn ->
        ResourceFetch.need(key, fn _opts -> {:ok, %{}} end, reason: "nobody chose")
      end
    end

    test "an unrecognised tolerance is refused rather than treated as lenient" do
      key = key(2)

      assert_raise ArgumentError, ~r/unknown ResourceFetch freshness/, fn ->
        ResourceFetch.need(key, fn _opts -> {:ok, %{}} end, freshness: :sort_of)
      end
    end
  end

  describe "a held body answers for free" do
    test "a body inside the declared tolerance costs zero upstream calls" do
      key = key(3)
      ResourceStore.put_resource(key, %{"id" => 3, "updated_at" => "2026-08-17T00:00:00Z"}, source: :webhook, version: "2026-08-17T00:00:00Z")

      {recorder, calls} = recorder({:ok, %{"id" => :upstream}})

      assert {:ok, %{"id" => 3}, meta} = ResourceFetch.need(key, recorder, freshness: {:max_age_ms, 60_000}, reason: "view")

      assert meta.outcome == :store
      assert meta.spent? == false
      assert count(calls) == 0
    end

    # `fresh_enough?/2` had no boundary coverage at all: every case sat far
    # inside or far outside the window, so widening or narrowing the comparison
    # changed nothing a test could see. These two bracket it to a second. The
    # inside case is a second short of the tolerance rather than exactly on it,
    # because the entry keeps ageing between the write and the read and an
    # exact-boundary assertion would be decided by scheduler jitter.
    test "a body just inside the declared tolerance is served" do
      key = key(41)
      ResourceStore.put_resource(key, %{"id" => 41}, source: :webhook)
      age_body!(key, 59_000)

      {recorder, calls} = recorder({:ok, %{"id" => :upstream}})

      assert {:ok, %{"id" => 41}, %{outcome: :store, spent?: false}} =
               ResourceFetch.need(key, recorder, freshness: {:max_age_ms, 60_000})

      assert count(calls) == 0
    end

    test "a body one millisecond past the declared tolerance is not served" do
      key = key(42)
      ResourceStore.put_resource(key, %{"id" => 42}, source: :webhook)
      age_body!(key, 60_001)

      {recorder, calls} = recorder({:ok, %{"id" => :upstream}})

      assert {:ok, %{"id" => :upstream}, %{outcome: :fetched, spent?: true}} =
               ResourceFetch.need(key, recorder, freshness: {:max_age_ms, 60_000})

      assert count(calls) == 1
    end

    test "a view tolerating any age never spends, however old the body is" do
      key = key(4)
      ResourceStore.put_resource(key, %{"id" => 4}, source: :webhook)
      age_body!(key, 48 * 60 * 60 * 1000)

      {recorder, calls} = recorder({:ok, %{"id" => :upstream}})

      assert {:ok, %{"id" => 4}, %{outcome: :store}} = ResourceFetch.need(key, recorder, freshness: :any)
      assert count(calls) == 0
    end

    # `:any` is not "forever". It is bounded by the store's retention window,
    # which is where a body stops being servable at all — and this crosses that
    # line rather than merely approaching it.
    test "a body past the store's retention window is not served, even to :any" do
      key = key(18)
      ResourceStore.put_resource(key, %{"id" => 18}, source: :webhook)
      age_body!(key, 73 * 60 * 60 * 1000)

      {recorder, calls} = recorder({:ok, %{"id" => :upstream}})

      assert {:ok, %{"id" => :upstream}, %{outcome: :fetched}} = ResourceFetch.need(key, recorder, freshness: :any)
      assert count(calls) == 1
    end

    test "a steady-state period with nothing needed spends nothing at all" do
      key = key(5)
      ResourceStore.put_resource(key, %{"id" => 5}, source: :webhook)

      {recorder, calls} = recorder({:ok, %{"id" => :upstream}})

      for _cycle <- 1..25 do
        assert {:ok, %{"id" => 5}, %{spent?: false}} = ResourceFetch.need(key, recorder, freshness: {:max_age_ms, 60_000})
      end

      assert count(calls) == 0
    end
  end

  describe "revalidation" do
    test "a stale entry revalidates with If-None-Match and a 304 refreshes it at no cost" do
      key = key(6)

      ResourceStore.put_resource(key, %{"id" => 6, "updated_at" => "2026-08-17T00:00:00Z"},
        source: :poll,
        version: "2026-08-17T00:00:00Z",
        etag: ~s("v1")
      )

      age_body!(key, 120_000)

      {recorder, calls} = recorder({:not_modified, ~s("v1")})

      assert {:ok, %{"id" => 6}, meta} = ResourceFetch.need(key, recorder, freshness: {:max_age_ms, 60_000}, reason: "sweep")

      # The request happened, and it carried the stored validator.
      assert [[etag: ~s("v1")]] = calls |> Agent.get(& &1.opts)
      assert meta.outcome == :revalidated
      # A 304 does not count against the primary rate limit.
      assert meta.spent? == false
      assert meta.version == "2026-08-17T00:00:00Z"

      # And the refresh is real: the very next read of the same tolerance is
      # served from the store, so a 304 buys back the whole window rather than
      # forcing a revalidation on every later read.
      assert {:ok, %{"id" => 6}, %{outcome: :store}} = ResourceFetch.need(key, recorder, freshness: {:max_age_ms, 60_000})
      assert count(calls) == 1
    end

    test "a validator is withheld when no body is held, so a 304 cannot return nothing" do
      key = key(7)
      # A validator with no body: the exact state a body ageing out of retention
      # leaves behind.
      ResourceStore.put_etag(key, ~s("orphan"))

      {recorder, calls} = recorder({:ok, %{"id" => 7}, ~s("fresh")})

      assert {:ok, %{"id" => 7}, %{outcome: :fetched}} = ResourceFetch.need(key, recorder, freshness: {:max_age_ms, 60_000})
      assert [[etag: nil]] = Agent.get(calls, & &1.opts)
    end

    test "a 304 with nothing to serve retries unconditionally instead of answering empty" do
      key = key(8)
      {:ok, calls} = Agent.start_link(fn -> %{count: 0, opts: []} end)

      fetcher = fn opts ->
        n = Agent.get_and_update(calls, fn state -> {state.count, %{count: state.count + 1, opts: state.opts ++ [opts]}} end)

        if n == 0, do: {:not_modified, ~s("elsewhere")}, else: {:ok, %{"id" => 8}, ~s("body")}
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{"id" => 8}, %{outcome: :fetched}} = ResourceFetch.need(key, fetcher, freshness: :any)
        end)

      assert log =~ "304 with no held body"
      assert count(calls) == 2
      assert Agent.get(calls, & &1.opts) == [[etag: nil], [etag: nil]]
      assert ResourceStore.data(key) == %{"id" => 8}
    end
  end

  describe "the strict-freshness bypass" do
    test "a strict read reaches upstream even when a brand-new body is held" do
      key = key(9)
      ResourceStore.put_resource(key, %{"id" => 9, "state" => "stale"}, source: :webhook, version: "2026-08-17T00:00:00Z")

      {recorder, calls} = recorder({:ok, %{"id" => 9, "state" => "fresh", "updated_at" => "2026-08-17T01:00:00Z"}})

      assert {:ok, answer, meta} = ResourceFetch.need(key, recorder, freshness: ResourceFetch.decision(), reason: "merge decision")

      # The bypass is proven by two things together: upstream was called, and the
      # answer is upstream's, not the one the store was holding a millisecond ago.
      assert count(calls) == 1
      assert answer["state"] == "fresh"
      assert meta.outcome == :fetched
      assert meta.spent?
      # The fresh answer also lands in the store, so the next tolerant reader
      # rides on the decision's spend rather than paying again.
      assert ResourceStore.data(key)["state"] == "fresh"
    end

    test "a strict read still bypasses when the held body is byte-identical to upstream's" do
      key = key(10)
      body = %{"id" => 10, "updated_at" => "2026-08-17T00:00:00Z"}
      ResourceStore.put_resource(key, body, source: :webhook, version: "2026-08-17T00:00:00Z")

      {recorder, calls} = recorder({:ok, body})

      assert {:ok, ^body, %{outcome: :fetched}} = ResourceFetch.need(key, recorder, freshness: :strict)
      # Identical data is not evidence the store was consulted; the call count is.
      assert count(calls) == 1
    end

    test "a strict read may revalidate, because a 304 is a fresh answer and not a cached one" do
      key = key(11)
      ResourceStore.put_resource(key, %{"id" => 11}, source: :poll, version: "v", etag: ~s("e1"))

      {recorder, calls} = recorder({:not_modified, ~s("e1")})

      assert {:ok, %{"id" => 11}, meta} = ResourceFetch.need(key, recorder, freshness: :strict)

      # Upstream was asked, and it asserted the body is current.
      assert count(calls) == 1
      assert Agent.get(calls, & &1.opts) == [[etag: ~s("e1")]]
      assert meta.outcome == :revalidated
      refute meta.spent?
    end

    test "decision/0 is the strict tolerance the dangerous read paths declare" do
      assert ResourceFetch.decision() == :strict
    end
  end
end

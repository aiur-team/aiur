defmodule Aiur.GitHub.ResourceFetch.WritesTest do
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

  describe "writing back" do
    test "a cold miss fetches once, stores the body and publishes the change" do
      key = key(12)
      ResourceStore.subscribe(key)

      {recorder, calls} = recorder({:ok, %{"id" => 12, "updated_at" => "2026-08-17T02:00:00Z"}, ~s("e12")})

      assert {:ok, _data, %{outcome: :fetched, version: "2026-08-17T02:00:00Z"}} =
               ResourceFetch.need(key, recorder, freshness: {:max_age_ms, 60_000})

      assert count(calls) == 1
      assert_receive {:github_resource_changed, %{key: ^key, data?: true}}, 1000
      assert ResourceStore.etag(key) == ~s("e12")

      # A second consumer inside the window rides on that one call.
      assert {:ok, _data, %{outcome: :store}} = ResourceFetch.need(key, recorder, freshness: {:max_age_ms, 60_000})
      assert count(calls) == 1
    end

    test "an edited resource is not suppressed: a changed updated_at is a new version" do
      key = key(13)
      ResourceStore.subscribe(key)

      {:ok, _data, first} =
        ResourceFetch.need(key, fn _opts -> {:ok, %{"id" => 13, "updated_at" => "2026-08-17T00:00:00Z"}} end, freshness: :strict)

      assert_receive {:github_resource_changed, %{key: ^key, data_version: "2026-08-17T00:00:00Z"}}, 1000

      {:ok, _data, second} =
        ResourceFetch.need(key, fn _opts -> {:ok, %{"id" => 13, "updated_at" => "2026-08-17T03:00:00Z"}} end, freshness: :strict)

      assert first.version == "2026-08-17T00:00:00Z"
      assert second.version == "2026-08-17T03:00:00Z"
      # The edit reached the subscribers rather than being swallowed as a
      # redelivery of the same identity.
      assert_receive {:github_resource_changed, %{key: ^key, data_version: "2026-08-17T03:00:00Z"}}, 1000
    end

    test "a caller may name the version itself when it is not an updated_at" do
      key = key(14)

      assert {:ok, _data, %{version: "17"}} =
               ResourceFetch.need(key, fn _opts -> {:ok, %{"head" => %{"sha" => "17"}}} end,
                 freshness: :strict,
                 version_fun: fn data -> data["head"]["sha"] end
               )
    end

    test "a revalidated 304 wakes no subscriber, because nothing changed" do
      key = key(15)
      ResourceStore.put_resource(key, %{"id" => 15}, source: :poll, version: "v", etag: ~s("e15"))
      age_body!(key, 120_000)
      ResourceStore.subscribe(key)

      {recorder, _calls} = recorder({:not_modified, ~s("e15")})

      assert {:ok, _data, %{outcome: :revalidated}} = ResourceFetch.need(key, recorder, freshness: {:max_age_ms, 60_000})

      refute_receive {:github_resource_changed, _change}, 100
    end

    # GitHub may legally answer a conditional request with a *different*
    # validator for content that did not change. The store treats `:etag` as
    # observable, so adopting it would broadcast a change to every subscriber of a
    # resource that did not change — a free wake, but a lying one.
    test "a 304 carrying a different validator still wakes no subscriber" do
      key = key(19)
      ResourceStore.put_resource(key, %{"id" => 19}, source: :poll, version: "v", etag: ~s("e19"))
      age_body!(key, 120_000)
      ResourceStore.subscribe(key)

      {recorder, _calls} = recorder({:not_modified, ~s(W/"e19-weak")})

      assert {:ok, _data, meta} = ResourceFetch.need(key, recorder, freshness: {:max_age_ms, 60_000})

      assert meta.outcome == :revalidated
      # The held validator just proved itself by earning this 304, so it is kept.
      assert meta.etag == ~s("e19")
      assert ResourceStore.etag(key) == ~s("e19")
      refute_receive {:github_resource_changed, _change}, 100
    end

    test "a fetcher answering with no resource is stored as no resource" do
      key = key(20)
      # The shape `PullRequests.fetch_open_pull_request_for_branch/2` answers with
      # when a ticket has no open pull request.
      {recorder, calls} = recorder({:ok, nil})

      assert {:ok, nil, %{outcome: :fetched, version: nil}} = ResourceFetch.need(key, recorder, freshness: :strict)
      assert count(calls) == 1
      assert ResourceStore.fetch(key) == :miss
    end

    test "a second 304 with still nothing to serve is an error, never an empty answer" do
      key = key(21)
      {recorder, calls} = recorder({:not_modified, ~s("elsewhere")})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :not_modified_without_body} = ResourceFetch.need(key, recorder, freshness: :any)
        end)

      assert log =~ "304 with no held body"
      assert count(calls) == 2
    end

    test "an unrecognised fetcher answer is an error rather than a stored surprise" do
      key = key(22)
      {recorder, _calls} = recorder(:surprise)

      assert {:error, {:unexpected_fetch_result, :surprise}} = ResourceFetch.need(key, recorder, freshness: :strict)
      assert ResourceStore.fetch(key) == :miss
    end
  end

  describe "degrading safely" do
    test "an unusable identity still answers from upstream and never raises" do
      {recorder, calls} = recorder({:ok, %{"id" => :direct}})

      # `key_for_repo/3` answers nil for anything it cannot address; the read
      # must behave exactly as it did before the store existed.
      assert {:ok, %{"id" => :direct}, %{outcome: :fetched}} =
               ResourceFetch.need(ResourceStore.key_for_repo(:issue, "not-a-repo", 1), recorder, freshness: {:max_age_ms, 60_000})

      assert count(calls) == 1
    end

    test "a store that is not running degrades to a direct fetch" do
      key = key(16)
      ResourceStore.put_resource(key, %{"id" => 16}, source: :webhook)

      stop_store!()

      {recorder, calls} = recorder({:ok, %{"id" => :direct}})

      assert {:ok, %{"id" => :direct}, %{outcome: :fetched}} = ResourceFetch.need(key, recorder, freshness: :any)
      assert count(calls) == 1
    end

    test "an upstream failure is returned rather than papered over with a stale body" do
      key = key(17)
      ResourceStore.put_resource(key, %{"id" => 17}, source: :webhook)
      age_body!(key, 120_000)

      {recorder, calls} = recorder({:error, :rate_limited})

      # Serving the body the caller already declared too old would be exactly
      # the silent staleness this path exists to prevent.
      assert {:error, :rate_limited} = ResourceFetch.need(key, recorder, freshness: {:max_age_ms, 60_000})
      assert count(calls) == 1
    end
  end

  # Since #2106 the webhook pipe deposits bodies for `:issue`, `:pull_request`,
  # comments, `:branch_pull_request` and `:pr_review` on every delivery, so a
  # revalidation and a delivery now contend on exactly the same keys. A `304`
  # confirms the validator this caller sent against the body this caller held —
  # it says nothing about a body somebody else deposited a microsecond ago, and
  # must not roll it back.
  describe "a revalidation racing a concurrent deposit" do
    test "never rolls the held body backwards, and never loses a deposit" do
      key = key(30)
      per_writer = 150
      me = self()

      ResourceStore.put_resource(key, %{"gen" => 0}, source: :webhook, version: "v0", etag: ~s("e30"))

      # Reports the first regression and then only waits for `:stop`, so the
      # failure is one clear message rather than a flood, and `:sampled` still
      # arrives to let the assertions below run in order.
      sampler =
        spawn_link(fn ->
          watch = fn watch, highest, reported? ->
            receive do
              :stop -> send(me, :sampled)
            after
              0 ->
                case :ets.lookup(ResourceStore.Table, key) do
                  [{^key, %{data: %{"gen" => gen}}}] when gen < highest ->
                    unless reported?, do: send(me, {:regressed, highest, gen})
                    watch.(watch, highest, true)

                  [{^key, %{data: %{"gen" => gen}}}] ->
                    watch.(watch, gen, reported?)

                  _other ->
                    watch.(watch, highest, reported?)
                end
            end
          end

          watch.(watch, 0, false)
        end)

      # Half the writers deliver newer bodies, as the webhook pipe does. The
      # other half revalidate, each one having read the entry before the
      # deposits it races.
      depositors =
        for _writer <- 1..2 do
          Task.async(fn ->
            for _step <- 1..per_writer do
              ResourceStore.update_resource(
                key,
                fn held -> %{"gen" => Map.get(held || %{}, "gen", 0) + 1} end,
                source: :webhook
              )
            end
          end)
        end

      revalidators =
        for _writer <- 1..2 do
          Task.async(fn ->
            for _step <- 1..per_writer do
              # Strict, so the store is never consulted for the answer and the
              # conditional request always runs. The read-then-write window
              # inside the revalidation is the thing under test.
              ResourceFetch.need(key, fn _opts -> {:not_modified, ~s("e30")} end, freshness: :strict)
            end
          end)
        end

      Enum.each(depositors ++ revalidators, &Task.await(&1, 60_000))

      send(sampler, :stop)
      assert_receive :sampled, 10_000

      refute_received {:regressed, _highest, _gen},
                      "a revalidation re-deposited a body it had read earlier and rolled a concurrent deposit back"

      assert ResourceStore.data(key) == %{"gen" => 2 * per_writer},
             "every deposit must survive a concurrent revalidation; a lower count is a lost update"
    end

    # A deposit that lands while the conditional request is still in flight is
    # already visible to the revalidation's own read, so it resolves as a normal
    # confirmation of the *newer* body — the caller is never handed the older one.
    test "a deposit during the request is answered with the newer body, not the older one" do
      key = key(31)
      ResourceStore.put_resource(key, %{"gen" => 1}, source: :poll, version: "v1", etag: ~s("e31"))

      fetcher = fn _opts ->
        ResourceStore.put_resource(key, %{"gen" => 2}, source: :webhook, version: "v2", etag: ~s("e31-new"))
        {:not_modified, ~s("e31")}
      end

      assert {:ok, answer, meta} = ResourceFetch.need(key, fetcher, freshness: :strict)

      assert answer == %{"gen" => 2}
      refute meta.spent?

      # The deposit's own metadata survives intact: nothing was re-stamped from
      # the revalidation's earlier read of the entry.
      assert ResourceStore.data(key) == %{"gen" => 2}
      assert ResourceStore.etag(key) == ~s("e31-new")
      {:ok, current} = ResourceStore.fetch(key)
      assert current.version == "v2"
      assert current.source == :webhook
    end

    test "an uncontended revalidation still refreshes the window and keeps its validator" do
      key = key(32)
      ResourceStore.put_resource(key, %{"gen" => 1}, source: :poll, version: "v1", etag: ~s("e32"))
      age_body!(key, 120_000)

      {recorder, calls} = recorder({:not_modified, ~s("e32")})

      assert {:ok, %{"gen" => 1}, %{outcome: :revalidated}} =
               ResourceFetch.need(key, recorder, freshness: {:max_age_ms, 60_000})

      # The refresh is real: the next read of the same tolerance is a store hit.
      assert {:ok, %{"gen" => 1}, %{outcome: :store}} = ResourceFetch.need(key, recorder, freshness: {:max_age_ms, 60_000})
      assert count(calls) == 1

      {:ok, entry} = ResourceStore.fetch(key)
      assert entry.version == "v1"
      assert entry.source == :poll
    end
  end
end

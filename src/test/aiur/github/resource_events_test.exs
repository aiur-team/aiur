defmodule Aiur.GitHub.ResourceEventsTest do
  @moduledoc """
  The store's change-event contract.

  These cases are the reason a dashboard page is allowed to be a pure reader.
  A page that cannot fetch and is never told a resource moved is not cheap, it
  is wrong — so every assertion here is about a write reaching a subscriber, or
  about a non-write correctly reaching nobody.
  """

  use Aiur.TestSupport

  alias Aiur.GitHub.{ResourceEvents, ResourceFetch, ResourceStore}

  @owner "aiur-team"
  @repo "aiur"
  @full_name "#{@owner}/#{@repo}"

  setup do
    if Process.whereis(ResourceStore) == nil do
      Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
    end

    ResourceStore.reset()
    on_exit(&ResourceStore.reset/0)
    :ok
  end

  defp key(id), do: ResourceStore.key(:issue_comment, @owner, @repo, id)

  describe "topics" do
    test "an identity topic names the exact resource" do
      assert ResourceEvents.topic(key(42)) == "github:resource:issue_comment:aiur-team/aiur:42"
    end

    # The two pipes disagree on casing — the poller uses the configured repo
    # identity, the webhook uses GitHub's delivered `full_name` — so a topic
    # that preserved case would let a writer and a subscriber miss each other
    # for a resource they both name correctly.
    test "a repository-scoped topic down-cases the repository" do
      assert ResourceEvents.type_topic(:issue_comment, "AIUR-Team/Aiur") ==
               "github:resource:issue_comment:aiur-team/aiur"
    end

    test "a repository that is not owner/name has no topic" do
      assert ResourceEvents.type_topic(:issue_comment, "aiur") == nil
      assert ResourceEvents.type_topic(:issue_comment, nil) == nil
    end

    # This module's own rule is that a write must never fail because the
    # announcement could not be addressed. Every addressing function therefore
    # answers `nil` for an unaddressable argument instead of raising — the store
    # calls them from inside a write, after the entry has already landed in ETS,
    # so a raise here writes the entry and kills the caller.
    test "an unaddressable type or key answers nil rather than raising" do
      assert ResourceEvents.type_topic("issue_comment") == nil
      assert ResourceEvents.type_topic(nil) == nil
      assert ResourceEvents.topic({"issue_comment", @owner, @repo, "1"}) == nil
      assert ResourceEvents.type_topic("issue_comment", "aiur-team/aiur") == nil
    end

    test "publishing an unaddressable key announces nothing and does not raise" do
      :ok = ResourceEvents.subscribe(:issue_comment)

      assert :ok = ResourceEvents.publish({"issue_comment", @owner, @repo, "1"}, %{etag: ~s("x")})
      assert :ok = ResourceEvents.publish({:issue_comment, %{}, @repo, "1"}, %{etag: ~s("x")})

      refute_receive {:github_resource_changed, _change}, 100
    end

    test "subscribing or unsubscribing with an unaddressable type does not raise" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = ResourceEvents.subscribe("issue_comment")
        end)

      assert log =~ "unknown resource type"
      assert :ok = ResourceEvents.unsubscribe("issue_comment")
    end
  end

  describe "a store write reaches its subscribers" do
    test "an identity subscriber is told when that resource is marked" do
      key = key(7)
      :ok = ResourceEvents.subscribe(key)

      ResourceStore.mark_processed(key, :webhook, "2026-08-17T00:00:00Z")

      assert_receive {:github_resource_changed, change}
      assert change.key == key
      assert change.resource_type == :issue_comment
      assert change.owner == @owner
      assert change.repo == @repo
      assert change.id == "7"
      assert change.source == :webhook
      assert change.version == "2026-08-17T00:00:00Z"
    end

    test "a type subscriber is told about any repository" do
      :ok = ResourceEvents.subscribe(:issue_comment)

      ResourceStore.put_etag(key(8), "W/\"abc\"")

      assert_receive {:github_resource_changed, %{id: "8", etag: "W/\"abc\""}}
    end

    test "a repository-scoped subscriber is told only about its repository" do
      :ok = ResourceEvents.subscribe(:issue_comment, @full_name)

      ResourceStore.put_etag(ResourceStore.key(:issue_comment, "other", "repo", 9), "W/\"x\"")
      ResourceStore.put_etag(key(10), "W/\"y\"")

      assert_receive {:github_resource_changed, %{id: "10"}}
      refute_received {:github_resource_changed, %{id: "9"}}
    end

    test "a subscriber to one identity hears nothing about a sibling" do
      :ok = ResourceEvents.subscribe(key(11))

      ResourceStore.put_etag(key(12), "W/\"z\"")

      refute_receive {:github_resource_changed, _change}, 100
    end

    test "unsubscribing stops the events" do
      key = key(13)
      :ok = ResourceEvents.subscribe(key)
      :ok = ResourceEvents.unsubscribe(key)

      ResourceStore.put_etag(key, "W/\"q\"")

      refute_receive {:github_resource_changed, _change}, 100
    end
  end

  describe "the cached body is the change a viewer is waiting for" do
    # The trap this guards: a body can arrive against a validator the sweep
    # already recorded. The held body is the only thing that decides whether a
    # page has anything to render, so a change check keyed on the ETag alone
    # would swallow exactly the write every viewer is waiting for.
    test "a first body publishes even though the validator did not move" do
      key = key(14)
      ResourceStore.put_etag(key, "W/\"same\"")
      :ok = ResourceEvents.subscribe(key)

      ResourceStore.put_resource(key, %{"body" => "hello"}, etag: "W/\"same\"", source: :fetch)

      assert_receive {:github_resource_changed, change}
      assert change.data? == true
      assert ResourceStore.data(key) == %{"body" => "hello"}
    end

    test "dropping a body publishes, because the page now has nothing to render" do
      key = key(15)
      ResourceStore.put_resource(key, %{"body" => "hello"})
      :ok = ResourceEvents.subscribe(key)

      ResourceStore.drop_data(key)

      assert_receive {:github_resource_changed, %{data?: false}}
      assert ResourceStore.fetch(key) == :miss
    end

    test "a validator with no body announces that there is still nothing to render" do
      key = key(16)
      :ok = ResourceEvents.subscribe(key)

      ResourceStore.put_etag(key, "W/\"validator-only\"")

      assert_receive {:github_resource_changed, change}
      assert change.etag == "W/\"validator-only\""
      assert change.data? == false
    end

    # A reader served a `304` learns only that nothing changed. Handing it an
    # entry with no body would let it mistake "unchanged" for "here it is", so a
    # bodyless entry is a miss no matter how good its validator is.
    test "an entry holding only a validator is a miss, not an empty answer" do
      key = key(20)
      ResourceStore.put_etag(key, "W/\"only\"")

      assert ResourceStore.fetch(key) == :miss
      assert ResourceStore.data(key) == nil
      assert ResourceStore.change_validator(key) == "W/\"only\""
    end
  end

  describe "a write that changes nothing is silent" do
    # Without this, a sweep re-recording unchanged validators across the whole
    # retention window would re-render every subscribed page — trading the poll
    # the store removes for a broadcast storm.
    test "re-recording the same validator publishes nothing" do
      key = key(17)
      ResourceStore.put_etag(key, "W/\"unchanged\"")
      :ok = ResourceEvents.subscribe(key)

      ResourceStore.put_etag(key, "W/\"unchanged\"")

      refute_receive {:github_resource_changed, _change}, 100
    end

    test "re-writing an identical body publishes nothing" do
      key = key(18)
      opts = [etag: "W/\"e\"", source: :fetch, version: "v1"]
      ResourceStore.put_resource(key, %{"body" => "same"}, opts)
      :ok = ResourceEvents.subscribe(key)

      ResourceStore.put_resource(key, %{"body" => "same"}, opts)

      refute_receive {:github_resource_changed, _change}, 100
    end

    # The storm this closes, and it had a real subscriber waiting for it: two
    # readers of the same unchanged resource write different `:source` values —
    # the ticket-detail path deposits `:fetch`, the poll deposits `:poll` — so
    # while that field counted as observable, every alternating cycle over a
    # quiet issue woke every subscriber of it, forever, for nothing.
    test "the same body re-deposited by a different pipe publishes nothing" do
      key = ResourceStore.key(:issue, @owner, @repo, 22)
      body = %{"state" => "open"}

      ResourceStore.put_resource(key, body, source: :fetch, version: "v1", etag: "W/\"e\"")
      :ok = ResourceEvents.subscribe(key)

      ResourceStore.put_resource(key, body, source: :poll, version: "v1", etag: "W/\"e\"")

      refute_receive {:github_resource_changed, _change}, 100
    end

    # The other half: which pipe paid is still *reported*, it is simply not a
    # change on its own. A page showing provenance keeps working.
    test "a real change still reports the pipe that deposited the body" do
      key = ResourceStore.key(:issue, @owner, @repo, 23)

      ResourceStore.put_resource(key, %{"state" => "open"}, source: :fetch, version: "v1")
      :ok = ResourceEvents.subscribe(key)

      ResourceStore.put_resource(key, %{"state" => "closed"}, source: :webhook, version: "v2")

      assert_receive {:github_resource_changed, change}
      assert change.source == :webhook
    end

    # A mark and a deposit each own their own field now, so neither answers for
    # the other. Before the split the last writer of `:source` won, and a
    # processed mark could claim authorship of a body it never wrote.
    test "a processed mark does not overwrite who deposited the body" do
      key = ResourceStore.key(:issue, @owner, @repo, 24)

      ResourceStore.put_resource(key, %{"state" => "open"}, source: :fetch, version: "v1")
      ResourceStore.mark_processed(key, :poll, "v1")

      assert {:ok, %{source: :fetch}} = ResourceStore.fetch(key)
    end

    # The one case the module's own comments say matters most, and the one a
    # weaker change check would swallow: only the body moved. Same validator,
    # same source, same version. Delete `:data` from the change check and this
    # is the test that fails.
    test "a body-only change publishes, with nothing else moving" do
      key = key(21)
      opts = [etag: "W/\"same\"", source: :fetch, version: "v1"]
      ResourceStore.put_resource(key, %{"body" => "first"}, opts)
      :ok = ResourceEvents.subscribe(key)

      ResourceStore.put_resource(key, %{"body" => "second"}, opts)

      assert_receive {:github_resource_changed, change}
      assert change.etag == "W/\"same\""
      assert change.source == :fetch
      assert change.data_version == "v1"
      assert ResourceStore.data(key) == %{"body" => "second"}
    end

    # `observable/1` names several members and the suite only isolated `:data`,
    # so dropping any of the others was an uncaught mutation. These isolate the
    # members no other case moves on its own: everything except the one member
    # under test is byte-identical across the two writes, so the publish can
    # only be attributed to that member.
    #
    # `:source` is deliberately *not* pinned here. Which pipe wrote an otherwise
    # identical body is a change nobody can see, and publishing on it is the
    # broadcast storm #2073's review named — so it is being removed from the
    # observable set on purpose, and a test asserting it still publishes would
    # be a guard against a fix.
    test "an etag-only change publishes" do
      key = key(22)
      opts = [source: :fetch, version: "v1"]

      ResourceStore.put_resource(key, %{"body" => "same"}, [etag: "W/\"first\""] ++ opts)
      :ok = ResourceEvents.subscribe(key)

      ResourceStore.put_resource(key, %{"body" => "same"}, [etag: "W/\"second\""] ++ opts)

      assert_receive {:github_resource_changed, change}
      assert change.etag == "W/\"second\""
      assert change.data_version == "v1"
    end

    test "a data-version-only change publishes" do
      key = key(23)
      opts = [etag: "W/\"same\"", source: :fetch]

      ResourceStore.put_resource(key, %{"body" => "same"}, [version: "v1"] ++ opts)
      :ok = ResourceEvents.subscribe(key)

      ResourceStore.put_resource(key, %{"body" => "same"}, [version: "v2"] ++ opts)

      assert_receive {:github_resource_changed, change}
      assert change.data_version == "v2"
      assert change.source == :fetch
    end

    # The sixth member, `:version`, is the processed marker, and the store
    # refuses to move it without `:processed_at_ms` on purpose — see the
    # moduledoc: advancing it alone would suppress a version nothing handled. So
    # it cannot be isolated through the public API, and this is the invariant
    # that makes that true, asserted rather than assumed.
    test "the processed marker never advances without its timestamp" do
      key = key(24)

      ResourceStore.put_resource(key, %{"body" => "same"}, source: :poll, version: "v1", processed: true)
      assert ResourceStore.processed?(key, "v1")

      # No `processed: true`, so a newer body version must leave the marker
      # where it is: the store must still say v2 is unhandled, which is what
      # stops the deposit from suppressing an event nothing has seen.
      ResourceStore.put_resource(key, %{"body" => "moved"}, source: :poll, version: "v2")

      assert {:ok, %{version: "v2"}} = ResourceStore.fetch(key)
      assert ResourceStore.processed?(key, "v1")
      refute ResourceStore.processed?(key, "v2")
    end

    test "an edit to the same resource does publish" do
      key = key(19)
      ResourceStore.put_resource(key, %{"body" => "first"}, etag: "W/\"e\"", version: "v1")
      :ok = ResourceEvents.subscribe(key)

      ResourceStore.put_resource(key, %{"body" => "edited"}, etag: "W/\"e\"", version: "v2")

      assert_receive {:github_resource_changed, %{data?: true, data_version: "v2"}}
      assert ResourceStore.data(key) == %{"body" => "edited"}
    end
  end

  describe "a view rides on somebody else's write" do
    # Acceptance criterion A4, at the seam a LiveView sits on: a writer that paid
    # for a round trip because *it* needed the data updates the watcher, and the
    # watcher spends nothing. The assertion is the upstream call count — one, made
    # by the writer — because that is what shows on the rate limit. A latency or
    # percentage assertion would pass against a view that fetched for itself.
    test "a subscribed watcher renders a writer's fetch without fetching itself" do
      key = key(30)
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      test = self()

      # The one upstream seam in this scenario. Both the writer and the watcher
      # go through `ResourceFetch.need/3`, and this fetcher is the only thing
      # either of them can use to leave for GitHub — so the counter below is the
      # scenario's real rate-limit cost, not a number the test incremented for
      # itself.
      upstream = fn _opts ->
        Agent.update(calls, &(&1 + 1))
        {:ok, %{"body" => "from the writer"}, "W/\"v1\""}
      end

      # Unlinked on purpose: the watcher ends on its own, and killing a linked
      # helper would take the test process with it.
      _watcher =
        spawn(fn ->
          :ok = ResourceEvents.subscribe(key)
          send(test, :watching)

          receive do
            {:github_resource_changed, %{key: ^key}} ->
              # A watcher re-reads through the same read-before-spend path a page
              # uses. If the writer's body had not reached the store, this would
              # miss and pay, and the count below would be two.
              {:ok, data, meta} = ResourceFetch.need(key, upstream, freshness: :any)
              send(test, {:rendered, data, meta.outcome, meta.spent?})
          after
            2_000 -> send(test, :never_told)
          end
        end)

      assert_receive :watching

      # The writer is an agent that needed the resource for its own reasons and
      # paid one round trip for it.
      assert {:ok, _data, %{outcome: :fetched, spent?: true}} = ResourceFetch.need(key, upstream, freshness: :any)

      assert_receive {:rendered, %{"body" => "from the writer"}, :store, false}

      assert Agent.get(calls, & &1) == 1,
             "the watcher must ride on the writer's fetch, not add an upstream call of its own"
    end

    # Non-vacuousness, asserted rather than claimed: an unsubscribed reader of a
    # resource nobody wrote pays for exactly one call through the same seam. If
    # the store stopped serving, the case above would read two here instead —
    # which is the shape of the failure it exists to catch.
    test "a reader with nobody's write to ride on pays for one call" do
      key = key(31)
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      upstream = fn _opts ->
        Agent.update(calls, &(&1 + 1))
        {:ok, %{"body" => "paid for"}, "W/\"v1\""}
      end

      assert {:ok, _data, %{outcome: :fetched, spent?: true}} = ResourceFetch.need(key, upstream, freshness: :any)
      assert Agent.get(calls, & &1) == 1
    end
  end

  describe "failing open" do
    # A cache that cannot announce itself must cost a stale view, never a lost
    # write — the same direction every other degraded path in the store takes.
    test "an unaddressable key is a no-op rather than a crash" do
      assert ResourceEvents.subscribe(nil) == :ok
      assert ResourceEvents.unsubscribe(nil) == :ok
      assert ResourceEvents.publish(nil, %{}) == :ok
    end

    test "subscribing to a repository it cannot parse is a no-op" do
      assert ResourceEvents.subscribe(:issue_comment, "not-a-repo") == :ok
      assert ResourceEvents.unsubscribe(:issue_comment, nil) == :ok
    end

    # Failing open must not become failing silently. Nothing ever publishes to a
    # topic for a type the store does not recognise, so a view subscribed to one
    # would stop updating and never say why.
    test "subscribing to an unknown type is refused out loud" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ResourceEvents.subscribe(:not_a_real_type) == :ok
          assert ResourceEvents.subscribe(:not_a_real_type, @full_name) == :ok
        end)

      assert log =~ "unknown resource type"
      assert log =~ "not_a_real_type"
    end

    # The write is what must survive. An entry keyed by hand can carry a member
    # no topic can be built from, and the announcement is the part that gives way.
    test "a key no topic can address does not fail the write" do
      key = {:issue_comment, @owner, @repo, 99}

      assert ResourceEvents.topic(key) == nil
      assert :ok = ResourceStore.put_resource(key, %{"body" => "stored anyway"}, source: :fetch)
      assert ResourceStore.data(key) == %{"body" => "stored anyway"}
    end

    test "subscribe_all covers every type the store recognises" do
      assert ResourceEvents.subscribe_all() == :ok

      for type <- ResourceStore.resource_types() do
        key = ResourceStore.key(type, @owner, @repo, "sub-all")
        ResourceStore.mark_processed(key, :poll, "v1")
        assert_receive {:github_resource_changed, %{resource_type: ^type}}
      end
    end
  end
end

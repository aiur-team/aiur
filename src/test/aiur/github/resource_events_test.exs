defmodule Aiur.GitHub.ResourceEventsTest do
  @moduledoc """
  The store's change-event contract.

  These cases are the reason a dashboard page is allowed to be a pure reader.
  A page that cannot fetch and is never told a resource moved is not cheap, it
  is wrong — so every assertion here is about a write reaching a subscriber, or
  about a non-write correctly reaching nobody.
  """

  use Aiur.TestSupport

  alias Aiur.GitHub.{ResourceEvents, ResourceStore}

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
      assert ResourceStore.etag(key) == "W/\"only\""
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

      # Unlinked on purpose: the watcher ends on its own, and killing a linked
      # helper would take the test process with it.
      _watcher =
        spawn(fn ->
          :ok = ResourceEvents.subscribe(key)
          send(test, :watching)

          receive do
            {:github_resource_changed, %{key: ^key}} ->
              # A watcher re-reads the store. It never fetches, which is why no
              # branch here touches the counter.
              send(test, {:rendered, ResourceStore.data(key)})
          after
            1_000 -> send(test, :never_told)
          end
        end)

      assert_receive :watching

      # The writer is an agent that needed the comment for its own reasons.
      Agent.update(calls, &(&1 + 1))
      ResourceStore.put_resource(key, %{"body" => "from the writer"}, source: :fetch, version: "v1")

      assert_receive {:rendered, %{"body" => "from the writer"}}
      assert Agent.get(calls, & &1) == 1, "the watcher must not have added a call of its own"

      refute_received :never_told
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

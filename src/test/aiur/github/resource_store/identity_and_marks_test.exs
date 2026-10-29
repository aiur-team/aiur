defmodule Aiur.GitHub.ResourceStore.IdentityAndMarksTest do
  use Aiur.TestSupport
  use Aiur.ResourceStoreTestSupport

  alias Aiur.GitHub.ResourceStore

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
end

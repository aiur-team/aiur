defmodule Aiur.Events.WebhookPollReviewReconciliationTest do
  @moduledoc """
  Reconciliation of a read that was not yet published, a repo with no webhook,
  and review submissions.

  Split out of `webhook_poll_reconciliation_test.exs`, whose moduledoc states
  what reconciliation means here.
  """

  use Aiur.TestSupport.WebhookPollFixture

  alias Aiur.Events.{Exchange, GithubWebhook}
  alias Aiur.GitHub.ResourceStore

  @repo "owner/repo"

  # F1. The validator for the comment *list* is a single endpoint-level
  # validator, so GitHub answering `304` to it suppresses every comment in the
  # list at once and no per-comment reconciliation can see inside that answer.
  # Recording it before publishing the comments it covers therefore had a
  # routine loss, not an exotic one: `ResourceStore` starts before `Publisher`
  # and the poller, so on SIGTERM the poller dies first while the store
  # checkpoints last.
  describe "a comment read but not yet published" do
    test "is published before the endpoint validator is recorded" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)
      resource = ResourceStore.key_for_repo(:issue_comments, @repo, ticket)
      :ok = ResourceStore.subscribe(resource)

      {_calls, {:ok, %{count: 1}}} = sweep([comment(9600, "must be published first")])

      order =
        for _step <- 1..2 do
          receive do
            {:event, %{topic: ^topic}} -> :comment_published
            {:github_resource_changed, %{resource_type: :issue_comments}} -> :validator_recorded
          after
            2_000 -> :nothing
          end
        end

      assert order == [:comment_published, :validator_recorded],
             "the crash window between the two must contain no validator: #{inspect(order)}"
    end

    test "is recovered from the store when GitHub answers 304 after a restart", %{store_path: store_path} do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      restart_store!(store_path)
      :ok = Exchange.subscribe(topic)

      {_calls, {:ok, %{count: 1}}} = sweep([comment(9601, "the one that would get lost")], etag: ~s("v2"))
      assert %{comment: %{"id" => 9601}} = await_event(topic)

      # The state a cycle that died between the read and the publish leaves
      # behind: the list and its validator are stored, the comment itself is
      # unmarked — `Publisher` marks only *after* a publish — and nobody ever saw
      # it. The replay window goes too, because a restart empties it.
      ResourceStore.forget(ResourceStore.key_for_repo(:issue_comment, @repo, 9601))
      clear_replay_window()

      assert :ok = ResourceStore.flush()
      restart_store!(store_path)

      # GitHub is right to answer 304: the list has not changed since the
      # validator was minted. The store has to be able to answer anyway.
      {calls, result} = sweep(:not_modified, etag: ~s("v2"))

      assert [%{etag: ~s("v2")}] = Enum.map(calls, &Map.take(&1, [:etag]))
      assert {:ok, %{count: 1}} = result

      assert %{comment: %{"id" => 9601}} = await_event(topic),
             "a 304 must publish what a 200 would have, or the comment is lost for the whole retention window"
    end

    test "an unchanged 304 still publishes nothing once the comment is marked" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)

      {_calls, {:ok, %{count: 1}}} = sweep([comment(9602, "seen once")], etag: ~s("v3"))
      assert %{comment: %{"id" => 9602}} = await_event(topic)
      clear_replay_window()

      for _cycle <- 1..3 do
        assert {:ok, %{count: 0}} = elem(sweep(:not_modified, etag: ~s("v3")), 1)
      end

      refute_event(topic)
    end

    # The other half of the store's validator/body contract, now enforced by the
    # store itself: `etag/1` does not offer a validator the store cannot serve a
    # body for, so the sweep never spends the empty `304` at all. The comment is
    # recovered by the *first* read rather than the second — one request instead
    # of two.
    test "a durable validator with no body is never sent, and the read recovers the comment", %{store_path: store_path} do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      restart_store!(store_path)
      :ok = Exchange.subscribe(topic)

      resource = ResourceStore.key_for_repo(:issue_comments, @repo, ticket)
      ResourceStore.put_etag(resource, ~s("bodyless"))
      assert :ok = ResourceStore.flush()
      restart_store!(store_path)

      assert ResourceStore.change_validator(resource) == ~s("bodyless"),
             "the validator is still recorded; it is simply not offered to a reader of bodies"

      {calls, result} = sweep([comment(9603, "recovered by the unconditional read")])

      assert [request] = calls
      refute Map.has_key?(request, :etag), "a validator with no body behind it must not be spent"
      assert {:ok, %{count: 1}} = result
      assert %{comment: %{"id" => 9603}} = await_event(topic)
    end
  end

  describe "a repo with no webhook" do
    # Acceptance criterion 6. Nothing about this path is conditional on webhook
    # transport, which is the point: an unproven repo never had a delivery, so
    # nothing is ever marked, so nothing is ever suppressed. It polls and
    # publishes exactly as it did before this store existed.
    test "publishes everything the sweep reads, exactly as before" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)

      {_calls, result} =
        sweep([
          comment(9006, "one", "2026-06-24T11:30:00Z"),
          comment(9007, "two", "2026-06-24T11:45:00Z")
        ])

      assert {:ok, %{count: 2}} = result
      assert %{comment: %{"id" => 9006}} = await_event(topic)
      assert %{comment: %{"id" => 9007}} = await_event(topic)
    end
  end

  # Review submissions are the last comment kind the poller still re-read at
  # full price every cycle (#2069). The webhook delivers `pull_request_review`
  # free and marks the `:pr_review` resource; the sweep re-read the same list
  # unconditionally. These pin the same reconciliation contract for reviews
  # that the issue-comment tests above pin for comments.
  describe "a review submission the webhook delivered" do
    # Acceptance criterion 3, applied to review submissions: published once by
    # the delivery, not again by the sweep.
    test "is published once by the delivery and not again by the sweep" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)

      review = review(9001, "its-everdred", "CHANGES_REQUESTED", "please rework this section", "2026-06-24T12:00:00Z")

      assert %{status: :published, published: [^fixture_topic0]} =
               GithubWebhook.handle_delivery("pull_request_review", review_delivery(review), repo: @repo)

      assert %{comment: %{"id" => 9001}} = await_event(fixture_topic0)

      # The sweep reads the very same review list back from GitHub.
      {calls, result} = review_sweep([review])

      assert {:ok, %{count: 0}} = result
      assert length(calls) == 1
      refute_event(fixture_topic0)
    end

    # Acceptance criterion 4, applied to review submissions. Nothing marked the
    # review, so the sweep publishes it — the delivery-loss case a blanket
    # skip-when-webhook-backed would drop.
    test "is recovered by the next sweep when its delivery was lost" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)

      review = review(9002, "its-everdred", "CHANGES_REQUESTED", "the 502'd one", "2026-06-24T12:00:00Z")

      {_calls, result} = review_sweep([review])

      assert {:ok, %{count: 1}} = result
      assert %{comment: %{"id" => 9002}} = await_event(fixture_topic0)
    end

    # The restart case, applied to reviews. The in-memory replay window empties
    # on restart, and so does the orchestrator's `pr_review_seen_at` watermark —
    # the first sweep after one re-reads the whole review list. The durable
    # `:pr_review` mark is what stops the old CHANGES_REQUESTED from waking the
    # agent again.
    test "stays suppressed across a restart of the replay window" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)

      review = review(9005, "its-everdred", "CHANGES_REQUESTED", "before the restart", "2026-06-24T12:00:00Z")

      assert %{status: :published, published: [^fixture_topic0]} =
               GithubWebhook.handle_delivery("pull_request_review", review_delivery(review), repo: @repo)

      assert %{comment: %{"id" => 9005}} = await_event(fixture_topic0)
      clear_replay_window()

      {_calls, result} = review_sweep([review])

      assert {:ok, %{count: 0}} = result
      refute_event(fixture_topic0)
    end
  end

  describe "review submission cost" do
    # Acceptance criterion 1, applied to review submissions: an unchanged review
    # list revalidates with If-None-Match and GitHub answers 304 — a request the
    # primary REST limit does not bill. The assertion is on the request the
    # poller actually sends.
    test "an unchanged review list revalidates with If-None-Match and publishes nothing" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)

      review = review(9003, "its-everdred", "CHANGES_REQUESTED", "seen once", "2026-06-24T12:00:00Z")

      # First sweep has no validator to send, so it is a full-price read.
      {first_calls, _result} = review_sweep([review], etag: ~s("rv1"))
      assert [request] = first_calls
      refute Map.has_key?(request, :etag)
      assert %{comment: %{"id" => 9003}} = await_event(fixture_topic0)

      # Second sweep sends it back and GitHub answers 304 — free.
      {second_calls, result} = review_sweep(:not_modified, etag: ~s("rv1"))

      assert [%{etag: ~s("rv1")}] = Enum.map(second_calls, &Map.take(&1, [:etag]))
      assert {:ok, %{count: 0, errors: []}} = result
      refute_event(fixture_topic0)
    end
  end
end

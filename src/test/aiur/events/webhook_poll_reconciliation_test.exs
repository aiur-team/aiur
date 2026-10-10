defmodule Aiur.Events.WebhookPollReconciliationTest do
  @moduledoc """
  The poll sweep as a reconciliation pass over the webhook pipe (#2069).

  Two requirements pull against each other and the tension is the point:

    * a comment the webhook delivered must be processed **once**, not again by
      the next sweep, and
    * a comment whose delivery was **lost** must still be recovered — 9 of 100
      measured deliveries returned 502 during a daemon restart, GitHub retried
      none, and none arrived later.

  A blanket "skip polling when the repo is webhook-backed" satisfies the first
  and silently loses the second. Suppressing per *resource identity* satisfies
  both: the sweep always runs and always reads, and only the individual comments
  some pipe already processed are held back.
  """

  use Aiur.TestSupport.WebhookPollFixture

  alias Aiur.Events.{Exchange, GithubWebhook}
  alias Aiur.GitHub.ResourceStore

  @repo "owner/repo"

  describe "a comment the webhook delivered" do
    # Acceptance criterion 3. The sweep still reads the comment back — that read
    # is what makes criterion 4 possible — but it must not publish it a second
    # time and wake the agent twice for one human comment.
    test "is published once by the delivery and not again by the sweep" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)

      assert %{status: :published, published: [^topic]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(9001, "review this"), repo: @repo)

      assert %{comment: %{"id" => 9001}} = await_event(topic)

      # The sweep reads the very same comment back from GitHub.
      {calls, result} = sweep([comment(9001, "review this")])

      assert {:ok, %{count: 0}} = result
      # The read still happened: this is reconciliation, not suppression of the
      # sweep itself.
      assert length(calls) == 1
      refute_event(topic)
    end

    # The in-memory replay window empties on every daemon restart, which is
    # exactly when this matters: the 502s that lost deliveries were measured
    # *during* a restart, so the sweep that runs right after one is the sweep
    # most likely to re-read a comment the pre-restart daemon already handled.
    test "stays suppressed across a restart of the in-memory replay window" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)

      assert %{status: :published, published: [^topic]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(9010, "before the restart"), repo: @repo)

      assert %{comment: %{"id" => 9010}} = await_event(topic)

      clear_replay_window()

      {_calls, result} = sweep([comment(9010, "before the restart")])

      assert {:ok, %{count: 0}} = result
      refute_event(topic)
    end
  end

  describe "a review thread reopened without a new comment" do
    test "wakes once for each unresolved generation" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      topic = fixture_topic0
      :ok = Exchange.subscribe(topic)

      thread_comment =
        comment(9_100, "still needs work")
        |> Map.put("review_thread_id", "PRRT_kwDOreopen")

      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery(
                 "pull_request_review_thread",
                 review_thread_delivery("unresolved", "2026-08-21T12:00:00Z"),
                 repo: @repo,
                 reconcile_fun: fn _hint -> :ok end
               )

      assert {:ok, %{count: 1}} = thread_sweep(thread_comment)
      assert_receive {:event, %{topic: ^topic, comment: %{"id" => 9_100}}}, 500

      clear_replay_window()
      assert {:ok, %{count: 0}} = thread_sweep(thread_comment)
      refute_receive {:event, %{topic: ^topic}}, 100

      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery(
                 "pull_request_review_thread",
                 review_thread_delivery("resolved", "2026-08-21T12:05:00Z"),
                 repo: @repo,
                 reconcile_fun: fn _hint -> :ok end
               )

      clear_replay_window()
      assert {:ok, %{count: 0}} = thread_sweep(thread_comment)
      refute_receive {:event, %{topic: ^topic}}, 100

      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery(
                 "pull_request_review_thread",
                 review_thread_delivery("unresolved", "2026-08-21T12:10:00Z"),
                 repo: @repo,
                 reconcile_fun: fn _hint -> :ok end
               )

      assert {:ok, %{count: 1}} = thread_sweep(thread_comment)
      assert_receive {:event, %{topic: ^topic, comment: %{"id" => 9_100}}}, 500

      clear_replay_window()
      assert {:ok, %{count: 0}} = thread_sweep(thread_comment)
    end
  end

  # An operator editing a comment to correct an agent's instructions is a normal
  # workflow here. A GitHub comment is mutable: an edit keeps the id and moves
  # only `updated_at`, so suppressing on identity alone would swallow that edit
  # for the store's full 72-hour retention, across restarts.
  #
  # Every case here first expires the volatile replay window. That is not test
  # convenience — it *is* the scenario. `Publisher`'s in-memory window suppresses
  # any repeat for an hour and always did, so an edit made minutes later is
  # suppressed on `main` too and proves nothing about this change. The regression
  # only exists past that hour, where the durable store is the sole remaining
  # gate, so these cases start where it is the only thing deciding.
  describe "an edited comment, more than an hour after posting" do
    test "re-publishes when the sweep sees a changed updated_at" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)

      assert %{status: :published, published: [^topic]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(9020, "run the wrong thing"), repo: @repo)

      assert %{comment: %{"body" => "run the wrong thing"}} = await_event(topic)
      clear_replay_window()

      # Operator corrects the instruction. Same comment id, later updated_at.
      {_calls, result} = sweep([comment(9020, "run the right thing", "2026-06-24T14:00:00Z")])

      assert {:ok, %{count: 1}} = result
      assert %{comment: %{"body" => "run the right thing"}} = await_event(topic)
    end

    test "re-publishes when the edit itself arrives as a delivery" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)

      assert %{status: :published, published: [^topic]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(9021, "first"), repo: @repo)

      assert %{comment: %{"body" => "first"}} = await_event(topic)
      clear_replay_window()

      edited =
        9021
        |> delivery("corrected")
        |> Map.put("action", "edited")
        |> put_in(["comment", "updated_at"], "2026-06-24T14:00:00Z")

      assert %{status: :published, published: [^topic]} =
               GithubWebhook.handle_delivery("issue_comment", edited, repo: @repo)

      assert %{comment: %{"body" => "corrected"}} = await_event(topic)
    end

    # The other half of the contract, and the reason this is a version check
    # rather than a shortened TTL: with the volatile window gone, an *unchanged*
    # comment re-read by the sweep is still suppressed, however many cycles run
    # over it. Shortening the TTL would have bought the edit back by giving up
    # exactly this.
    test "an unchanged re-fetch is still suppressed once the window has expired" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)

      assert %{status: :published, published: [^topic]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(9022, "unchanged"), repo: @repo)

      assert %{comment: %{"id" => 9022}} = await_event(topic)
      clear_replay_window()

      for _cycle <- 1..3 do
        assert {:ok, %{count: 0}} = elem(sweep([comment(9022, "unchanged")]), 1)
      end

      refute_event(topic)
    end

    test "a version change is what unsuppresses, not the passage of time" do
      key = ResourceStore.key_for_repo(:issue_comment, @repo, 9023)

      ResourceStore.mark_processed(key, :webhook, "2026-06-24T12:00:00Z")

      assert ResourceStore.processed?(key, "2026-06-24T12:00:00Z")
      refute ResourceStore.processed?(key, "2026-06-24T14:00:00Z")

      # Re-marking at the new version suppresses that version in turn, so an
      # edit wakes the agent once rather than every cycle thereafter.
      ResourceStore.mark_processed(key, :poll, "2026-06-24T14:00:00Z")
      assert ResourceStore.processed?(key, "2026-06-24T14:00:00Z")
      refute ResourceStore.processed?(key, "2026-06-24T12:00:00Z")
    end
  end

  describe "a comment whose delivery was lost" do
    # Acceptance criterion 4. Nothing marked this comment, so nothing suppresses
    # it. This is the case a blanket skip-when-webhook-backed would drop on the
    # floor, and the 9% measured loss rate is why it cannot be dropped.
    test "is recovered by the next sweep" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)

      {_calls, result} = sweep([comment(9002, "the 502'd one")])

      assert {:ok, %{count: 1}} = result
      assert %{comment: %{"id" => 9002}} = await_event(topic)
    end

    # The hazard a timestamp watermark would have: comment 9004 is delivered and
    # marks the newest position, while the older 9003 was lost. "Anything newer
    # than the last thing I processed" would silently discard 9003 forever.
    # Identity suppression cannot make that mistake.
    test "is recovered even when a newer sibling was delivered successfully" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)

      assert %{status: :published, published: [^topic]} =
               GithubWebhook.handle_delivery("issue_comment", delivery(9004, "newer, delivered"), repo: @repo)

      assert %{comment: %{"id" => 9004}} = await_event(topic)

      {_calls, result} =
        sweep([
          comment(9003, "older, lost", "2026-06-24T11:30:00Z"),
          comment(9004, "newer, delivered", "2026-06-24T11:45:00Z")
        ])

      assert {:ok, %{count: 1}} = result
      assert %{comment: %{"id" => 9003}} = await_event(topic)
      refute_event(topic)
    end
  end

  describe "cost" do
    # Acceptance criterion 1. A steady-state cycle over unchanged resources
    # should cost nothing, not merely less: a 304 does not count against
    # GitHub's primary REST limit. The assertion is on the request the poller
    # actually sends, because that is the thing that either is or is not
    # conditional.
    test "an unchanged sweep revalidates with If-None-Match and publishes nothing" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)

      # First sweep has no validator to send, so it is a full-price read.
      {first_calls, _result} = sweep([comment(9005, "first read")], etag: ~s("v1"))
      assert [request] = first_calls
      refute Map.has_key?(request, :etag)
      assert %{comment: %{"id" => 9005}} = await_event(topic)

      # Second sweep sends it back and GitHub answers 304 — free.
      {second_calls, result} = sweep(:not_modified)

      assert [%{etag: ~s("v1")}] = Enum.map(second_calls, &Map.take(&1, [:etag]))
      assert {:ok, %{count: 0, errors: []}} = result
      refute_event(topic)
    end

    # Acceptance criterion 5, at the level that matters operationally: the
    # validator has to come back after the process holding it dies, or the first
    # sweep of every boot is a full-price read of every watched ticket.
    test "the validator survives a restart of the store, and so does the answer", %{store_path: store_path} do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      # Point the store at a real file for this case: with no resolvable state
      # directory it runs in memory, which would make the restart trivially
      # pass nothing rather than prove the checkpoint round-trip.
      restart_store!(store_path)
      :ok = Exchange.subscribe(topic)

      # A real full-price read is what mints the validator, so the checkpoint
      # holds what the daemon actually had: the list *and* its validator. A case
      # that only checks the validator came back cannot tell a working cache from
      # one that revalidates its way to an empty answer forever.
      {_calls, {:ok, %{count: 1}}} = sweep([comment(9008, "read before the restart")], etag: ~s("survives"))
      assert %{comment: %{"id" => 9008}} = await_event(topic)

      assert :ok = ResourceStore.flush()
      assert File.exists?(store_path)

      restart_store!(store_path)

      {calls, result} = sweep(:not_modified)

      assert [%{etag: ~s("survives")}] = Enum.map(calls, &Map.take(&1, [:etag]))
      assert {:ok, %{errors: []}} = result

      resource = ResourceStore.key_for_repo(:issue_comments, @repo, ticket)

      assert ResourceStore.data(resource) == [comment(9008, "read before the restart")],
             "a validator whose body did not survive can only ever answer 304 and nothing"
    end
  end
end

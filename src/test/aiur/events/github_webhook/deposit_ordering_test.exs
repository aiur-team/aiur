defmodule Aiur.Events.GithubWebhook.DepositOrderingTest do
  @moduledoc """
  Deposit ordering, publication and suppression: a delivery never walks a resource backwards.

  Split out of `deposit_test.exs`, whose moduledoc states what these suites
  assert and why.
  """

  use Aiur.TestSupport.DepositCase

  alias Aiur.Events.{Exchange, GithubWebhook}
  alias Aiur.GitHub.ResourceStore

  @repo "owner/repo"
  @bot "its-applekid"

  describe "ordering — a delayed delivery cannot walk a resource backwards" do
    test "an older snapshot of the same issue is refused" do
      number = ticket_number()
      # Two deliveries carry the issue: a label change, then a comment delivery
      # that was delayed and is still holding the pre-change label set.
      GithubWebhook.handle_delivery(
        "issues",
        put_in(issues_delivery("labeled"), ["issue", "updated_at"], "2026-06-24T13:00:00Z"),
        repo: @repo,
        reconcile_fun: fn _ -> :ok end
      )

      stale =
        9801
        |> issue_comment_delivery()
        |> put_in(["issue", "updated_at"], "2026-06-24T09:00:00Z")
        |> put_in(["issue", "labels"], [%{"name" => "agent:ci-wait"}])

      GithubWebhook.handle_delivery("issue_comment", stale, repo: @repo)

      # The newer state stands, and is still described by its own version.
      assert {:ok, %{data: [%{"name" => "agent:in-progress"}], version: "2026-06-24T13:00:00Z"}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:issue_labels, @repo, number))

      # The comment the delayed delivery was actually about is still deposited:
      # nothing older was held for it.
      assert {:ok, %{data: %{"id" => 9801}}} = ResourceStore.fetch(ResourceStore.key_for_repo(:issue_comment, @repo, 9801))
    end

    test "an equal version still writes, because the body may have changed under it" do
      GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9802, "first"), repo: @repo)

      same_version =
        9802
        |> issue_comment_delivery("second")
        |> Map.put("action", "edited")

      GithubWebhook.handle_delivery("issue_comment", same_version, repo: @repo)

      assert {:ok, %{data: %{"body" => "second"}}} =
               ResourceStore.fetch(ResourceStore.key_for_repo(:issue_comment, @repo, 9802))
    end
  end

  describe "R5 — the deposit publishes the change" do
    test "a subscribed view is woken by the delivery's deposit with no read of its own" do
      key = ResourceStore.key_for_repo(:issue_comment, @repo, 9301)
      :ok = ResourceStore.subscribe(key)

      GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9301), repo: @repo)

      assert_receive {:github_resource_changed, %{key: ^key}}, 1_000
    end

    test "a whole-type subscriber is woken for the issue the delivery carried" do
      ticket = ticket_id()
      :ok = ResourceStore.subscribe_type(:issue)

      GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9302), repo: @repo)

      assert_receive {:github_resource_changed, %{key: {:issue, "owner", "repo", ^ticket}}}, 1_000
    end
  end

  describe "KTD5 — a deposit never advances a suppression mark" do
    test "the deposited body is held without marking the resource processed" do
      key = ResourceStore.key_for_repo(:issue_comment, @repo, 9401)

      # The publish is stubbed out so only the deposit runs. This is the
      # delivery of a comment nothing has handled yet.
      GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9401),
        repo: @repo,
        publish_fun: fn _topic, _payload, _opts -> :filtered end
      )

      # The body is held...
      assert {:ok, %{data: %{"id" => 9401}}} = ResourceStore.fetch(key)
      # ...and the resource is still unprocessed, at its own version and at any
      # other. A mark here would let the sweep skip a comment nothing handled.
      refute ResourceStore.processed?(key, "2026-06-24T12:00:00Z")
      refute ResourceStore.processed?(key, nil)
    end

    test "an older sibling stays recoverable after a newer one was delivered" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      # The hazard a timestamp watermark has and identity-plus-version does not:
      # 9403 was delivered, 9402 was lost, and the sweep must still find 9402.
      :ok = Exchange.subscribe(topic)

      assert %{status: :published} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9403, "newer"), repo: @repo)

      assert %{comment: %{"id" => 9403}} = await_event(topic)

      {_calls, result} =
        sweep([
          comment(9402, "older, lost", "2026-06-24T11:30:00Z"),
          comment(9403, "newer", "2026-06-24T12:00:00Z")
        ])

      assert {:ok, %{count: 1}} = result
      assert %{comment: %{"id" => 9402}} = await_event(topic)
    end
  end

  describe "A8 — an edited resource is not suppressed" do
    test "an edit replaces the body and republishes at the new version" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)
      key = ResourceStore.key_for_repo(:issue_comment, @repo, 9501)

      assert %{status: :published} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9501, "first"), repo: @repo)

      assert %{comment: %{"body" => "first"}} = await_event(topic)
      assert ResourceStore.processed?(key, "2026-06-24T12:00:00Z")

      edited =
        9501
        |> issue_comment_delivery("corrected")
        |> Map.put("action", "edited")
        |> put_in(["comment", "updated_at"], "2026-06-24T14:00:00Z")

      # Only the durable store is under test here. The in-memory replay window
      # keys on the comment id alone, so it would suppress the edit whatever the
      # store said — and it empties on every daemon restart, which is the state
      # this asserts against.
      clear_replay_window()

      assert %{status: :published} = GithubWebhook.handle_delivery("issue_comment", edited, repo: @repo)

      # The event fired again — the changed `updated_at` invalidated the mark.
      assert %{comment: %{"body" => "corrected"}} = await_event(topic)
      # And the store now serves the edited body, at the edited version.
      assert {:ok, %{data: %{"body" => "corrected"}, version: "2026-06-24T14:00:00Z"}} = ResourceStore.fetch(key)
    end
  end

  # KTD4, guarded rather than introduced here: the sweep this exercises is the
  # existing comment poller, and these cases assert the deposit did not change
  # what it recovers. They would pass against an implementation that deposited
  # nothing, which is the point — that is the behavior the deposit must preserve.
  describe "A6 — a lost delivery is still recovered by the sweep" do
    test "a comment whose delivery never arrived is published by the sweep, which still reads" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)

      {calls, result} = sweep([comment(9601, "the 502'd one")])

      # KTD4: the store is a cache with reconciliation. The sweep is not
      # conditional on webhook transport, so a lost delivery costs a read and
      # loses nothing.
      assert length(calls) == 1
      assert {:ok, %{count: 1}} = result
      assert %{comment: %{"id" => 9601}} = await_event(topic)
    end

    test "a delivery-populated entry does not stop the sweep from reading" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)

      assert %{status: :published} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(9602), repo: @repo)

      assert %{comment: %{"id" => 9602}} = await_event(topic)

      {calls, result} = sweep([comment(9602, "review this"), comment(9603, "lost sibling")])

      # The read still happens — that is what makes recovery possible at all —
      # the delivered comment is not published twice, and the sibling nobody
      # delivered is recovered.
      assert length(calls) == 1
      assert {:ok, %{count: 1}} = result
      assert %{comment: %{"id" => 9603}} = await_event(topic)
      refute_event(topic)
    end
  end

  describe "the bot self-loop stays suppressed" do
    test "a delivery for Aiur's own comment caches the body and wakes nobody" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)
      key = ResourceStore.key_for_repo(:issue_comment, @repo, 9701)

      delivery = issue_comment_delivery(9701, "posted by the fleet", @bot)

      # No publish: the actor is the configured `bot_account`.
      assert %{status: :published, published: []} = GithubWebhook.handle_delivery("issue_comment", delivery, repo: @repo)

      refute_event(topic)

      # The body is cached, because a change Aiur made is exactly the change it
      # should never have to read back...
      assert {:ok, %{data: %{"body" => "posted by the fleet"}}} = ResourceStore.fetch(key)

      # ...and the deposit did not mark it processed, so the filter — not the
      # store — is still what suppresses the self-loop.
      refute ResourceStore.processed?(key, "2026-06-24T12:00:00Z")
    end

    # Guards the surrounding filter, not the deposit: a deposit that started
    # marking resources processed would still leave this passing, which is why
    # the `refute processed?` assertion above is the one that pins the invariant.
    test "the self-loop stays filtered on redelivery of the same comment" do
      ticket = ticket_id()
      topic = "ticket.#{ticket}.issue.commented"
      :ok = Exchange.subscribe(topic)
      delivery = issue_comment_delivery(9702, "posted by the fleet", @bot)

      assert %{status: :published, published: []} = GithubWebhook.handle_delivery("issue_comment", delivery, repo: @repo)
      assert %{status: :published, published: []} = GithubWebhook.handle_delivery("issue_comment", delivery, repo: @repo)

      refute_event(topic)
    end
  end
end

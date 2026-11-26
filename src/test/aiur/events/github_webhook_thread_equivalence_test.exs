defmodule Aiur.Events.GithubWebhookThreadEquivalenceTest do
  @moduledoc """
  Review-thread comments coalesce to one wake across the poller and the webhook.

  Split out of `github_webhook_equivalence_test.exs`, whose moduledoc states
  what equivalence means here.
  """

  use Aiur.TestSupport.WebhookEquivalenceFixture

  alias Aiur.Events.{Exchange, GithubCommentsPoller, GithubWebhook}

  @repo "owner/repo"

  # The review-thread coalescing cases. `GithubCommentsPoller` keys thread
  # comments on the GraphQL thread node id (`{repo, "pr_review_thread:901",
  # "PRRT_..."}`); the webhook now resolves that same id from the delivered
  # comment's `node_id` (`GithubWebhook.ThreadResolver`), so the two pipes
  # derive the same key and `Publisher` collapses them into one wake (#2081).
  #
  # The earlier review-comment equivalence case injects a comment with no
  # `review_thread_id`, which takes both pipes' per-comment fallback branches
  # and says nothing about thread granularity. These cases use the shape the
  # poller's batch actually produces and the delivery GitHub actually sends.
  @thread_id "PRRT_kwDOabc123"

  defp thread_comment do
    %{
      "id" => 7_007,
      "review_thread_id" => @thread_id,
      "body" => "extract this into a helper",
      "created_at" => "2026-06-24T12:00:00Z",
      "updated_at" => "2026-06-24T12:00:00Z",
      "html_url" => "https://github.com/owner/repo/pull/901#discussion_r7007",
      "path" => "lib/foo.ex",
      "line" => 12,
      "user" => %{"login" => "its-everdred"}
    }
  end

  # The delivery for the comment above, as GitHub actually sends it: the full
  # REST review comment including its own `node_id`, which the resolver turns
  # back into `@thread_id`.
  defp thread_comment_delivery(comment) do
    ticket = ticket_id()
    fixture_value0 = "aiur/#{ticket}-some-slug"

    %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "comment" => comment,
      "pull_request" => %{"number" => 901, "head" => %{"ref" => fixture_value0, "sha" => "deadbeef"}},
      "sender" => %{"login" => "its-everdred"}
    }
  end

  defp comment_on_thread(id, updated_at) do
    %{
      "body" => "feedback on the same thread",
      "created_at" => "2026-06-24T12:00:00Z",
      "updated_at" => updated_at,
      "path" => "lib/foo.ex",
      "line" => 12,
      "user" => %{"login" => "its-everdred"}
    }
    |> Map.merge(%{
      "id" => id,
      "node_id" => "PRRC_kwD#{id}",
      "html_url" => "https://github.com/owner/repo/pull/901#discussion_r#{id}"
    })
  end

  test "review thread comment: poller and webhook coalesce to one wake" do
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
    :ok = Exchange.subscribe(fixture_topic0)

    polled_comment = thread_comment()

    assert {:ok, %{count: 1}} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: @repo,
               review_submission_targets: MapSet.new([]),
               open_pull_requests_by_target: %{ticket => %{"number" => 901}},
               comment_batch: %{
                 ticket => %{issue_comments: [], pr_issue_comments: [], review_thread_comments: [polled_comment]}
               }
             )

    assert_receive {:event, %{topic: ^fixture_topic0, comment: %{"review_thread_id" => @thread_id}}},
                   500

    # The webhook delivery carries the comment's own node id; the resolver maps
    # it to the same thread the poller keyed on. Dedup deliberately NOT cleared:
    # if the keys agree, this publish is suppressed as a duplicate.
    delivery =
      thread_comment_delivery(
        polled_comment
        |> Map.delete("review_thread_id")
        |> Map.put("node_id", "PRRC_kwDOabc123")
      )

    assert %{status: :published, published: []} =
             GithubWebhook.handle_delivery("pull_request_review_comment", delivery,
               repo: @repo,
               request_fun: thread_resolver(@thread_id)
             )

    # One comment, one wake — whether it arrived by poll or by webhook.
    refute_receive {:event, %{topic: ^fixture_topic0}}, 200
  end

  test "a review thread comment delivered by webhook is not re-published by the poll" do
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
    :ok = Exchange.subscribe(fixture_topic0)

    comment = %{
      "id" => 7_007,
      "node_id" => "PRRC_kwDOabc123",
      "body" => "extract this into a helper",
      "created_at" => "2026-06-24T12:00:00Z",
      "updated_at" => "2026-06-24T12:00:00Z",
      "html_url" => "https://github.com/owner/repo/pull/901#discussion_r7007",
      "path" => "lib/foo.ex",
      "line" => 12,
      "user" => %{"login" => "its-everdred"}
    }

    assert %{status: :published, published: [^fixture_topic0]} =
             GithubWebhook.handle_delivery("pull_request_review_comment", thread_comment_delivery(comment),
               repo: @repo,
               request_fun: thread_resolver(@thread_id)
             )

    assert_receive {:event, %{topic: ^fixture_topic0, comment: %{"review_thread_id" => @thread_id}}},
                   500

    # The reconciliation poll then reads the same thread. The in-memory replay
    # window is cleared first so the durable resource mark — `{:pr_review_thread,
    # owner, repo, thread_id}` written by both pipes — is the only thing left
    # suppressing the re-publish. That is the restart-proof half of the seam.
    clear_replay_window()
    thread = Map.put(comment, "review_thread_id", @thread_id)

    assert {:ok, %{count: 0}} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: @repo,
               review_submission_targets: MapSet.new([]),
               open_pull_requests_by_target: %{ticket => %{"number" => 901}},
               comment_batch: %{
                 ticket => %{issue_comments: [], pr_issue_comments: [], review_thread_comments: [thread]}
               }
             )

    refute_receive {:event, %{topic: ^fixture_topic0}}, 200
  end

  # Acceptance criterion 4, and the half of the change a reviewer must evaluate
  # (the issue's requirement 4): a reviewer adding several comments to one
  # thread wakes the agent once, not once per comment. This is the webhook's
  # previous behaviour, now changed — before #2081 a second comment on the same
  # thread was a distinct per-comment key and woke again.
  test "several comments on one review thread produce one agent wake" do
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
    :ok = Exchange.subscribe(fixture_topic0)

    first = comment_on_thread(7_007, "2026-06-24T12:00:00Z")
    second = comment_on_thread(7_008, "2026-06-24T12:05:00Z")

    # First comment wakes the agent once...
    assert %{status: :published, published: [^fixture_topic0]} =
             GithubWebhook.handle_delivery("pull_request_review_comment", thread_comment_delivery(first),
               repo: @repo,
               request_fun: thread_resolver(@thread_id)
             )

    assert_receive {:event, %{topic: ^fixture_topic0, comment: %{"id" => 7_007}}}, 500

    # ...a follow-up comment on the same thread within the replay window does
    # not wake a second time. Newer `updated_at`, so only the thread key — not
    # the resource version — is what suppresses it.
    assert %{status: :published, published: []} =
             GithubWebhook.handle_delivery("pull_request_review_comment", thread_comment_delivery(second),
               repo: @repo,
               request_fun: thread_resolver(@thread_id)
             )

    refute_receive {:event, %{topic: ^fixture_topic0}}, 200
  end

  # The fail-open degradation, pinned deliberately. Thread granularity is the
  # chosen behaviour, but resolving the thread needs the delivered comment's
  # `node_id` and a working lookup; when either is missing the webhook falls
  # back to per-comment keying — exactly the pre-#2081 behaviour, divergence
  # included. That is the safe direction: a duplicate wake is recoverable, a
  # dropped delivery is not, so a failure must cost a possible extra wake, never
  # a lost comment.
  test "an unresolvable review thread delivery falls back to per-comment keying" do
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
    :ok = Exchange.subscribe(fixture_topic0)

    # No `node_id`, so the resolver is never consulted and the delivery keys per
    # comment, as before #2081.
    delivery =
      thread_comment_delivery(thread_comment() |> Map.delete("review_thread_id"))

    assert %{status: :published, published: [^fixture_topic0]} =
             GithubWebhook.handle_delivery("pull_request_review_comment", delivery, repo: @repo)

    assert_receive {:event, %{topic: ^fixture_topic0} = event}, 500
    refute Map.has_key?(event.comment, "review_thread_id")
  end

  test "the same event seen by both producers wakes a consumer exactly once" do
    ticket = ticket_id()
    number = ticket_number()
    fixture_topic0 = "ticket.#{ticket}.issue.commented"
    :ok = Exchange.subscribe(fixture_topic0)

    comment = %{
      "id" => 2_002,
      "body" => "one wake only",
      "created_at" => "2026-06-24T12:00:00Z",
      "updated_at" => "2026-06-24T12:00:00Z",
      "user" => %{"login" => "its-everdred"}
    }

    delivery = %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "issue" => %{"number" => number},
      "comment" => comment,
      "sender" => %{"login" => "its-everdred"}
    }

    assert %{status: :published, published: [^fixture_topic0]} =
             GithubWebhook.handle_delivery("issue_comment", delivery, repo: @repo)

    assert_receive {:event, %{topic: ^fixture_topic0}}, 500

    # The reconciliation poll then sees the same comment. Sharing the poller's
    # dedup key is what keeps this from becoming a second wake.
    assert {:ok, %{count: 0}} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: @repo,
               comment_batch: %{ticket => %{issue_comments: [comment], open_pull_request: nil}}
             )

    refute_receive {:event, %{topic: ^fixture_topic0}}, 200
  end
end

defmodule Aiur.Events.GithubWebhookEquivalenceTest do
  @moduledoc """
  The central test of W-3: for the same underlying GitHub event, the webhook
  path and the polling path must publish events a consumer cannot tell apart.

  Each case drives the real poller (`GithubCommentsPoller` / `GithubFirehose`)
  with a stubbed transport, captures the event the Exchange delivered, clears
  the Publisher dedup window, drives the real webhook path with the delivery
  GitHub would have sent for that same event, and compares the two events.

  Only `:id` (a monotonic per-publish counter) and `:ticket_observation` (which
  stamps the wall clock of the publish itself) are excluded — everything a
  consumer routes, filters, or renders on must be identical.

  One known divergence is pinned rather than asserted away, rooted in the
  same cause — a GraphQL-only value that no webhook delivery can carry:

    * `review_decision`, which changes whether `ReviewFreshness` suppresses
      rework on an APPROVED pull request.

  The old `review_thread_id` divergence is gone: both pipes now key review
  thread comments on the thread node id (the webhook resolves it in the
  delivery path), so the coalescing cases below assert that a single inline
  comment wakes the agent exactly once whichever pipe saw it first.
  """

  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, GithubCommentsPoller, GithubFirehose, GithubWebhook, Publisher}
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Orchestrator.ReviewFreshness
  alias Aiur.Workflow

  @repo "owner/repo"
  @dedup_table Aiur.Events.Publisher.Dedup

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: @repo,
      tracker_label_prefix: "aiur"
    )

    Publisher.set_tracked_fn(fn _ -> true end)
    clear_dedup()

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)
      Publisher.set_tracked_fn(fn _ -> true end)
      clear_dedup()

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end)

    :ok
  end

  test "issue comment: polling and webhook publish indistinguishable events" do
    :ok = Exchange.subscribe("ticket.42.issue.commented")

    # `html_url` is present because `CommentPollBatch.normalize_comments/1`
    # always emits it; a fixture without it is a shape the poller never produces.
    comment = %{
      "id" => 1_001,
      "body" => "please rework this",
      "created_at" => "2026-06-24T12:00:00Z",
      "updated_at" => "2026-06-24T12:00:00Z",
      "html_url" => "https://github.com/owner/repo/issues/42#issuecomment-1001",
      "user" => %{"login" => "its-everdred"}
    }

    assert {:ok, %{count: 1}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: @repo,
               comment_batch: %{"42" => %{issue_comments: [comment], open_pull_request: nil}}
             )

    polled = await_event("ticket.42.issue.commented")
    clear_dedup()

    delivery = %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "issue" => %{"number" => 42, "title" => "a ticket"},
      "comment" => comment,
      "sender" => %{"login" => "its-everdred"}
    }

    assert %{status: :published, published: ["ticket.42.issue.commented"]} =
             GithubWebhook.handle_delivery("issue_comment", delivery, repo: @repo)

    pushed = await_event("ticket.42.issue.commented")

    assert_indistinguishable(polled, pushed)
  end

  test "pull request review submission: polling and webhook publish indistinguishable events" do
    :ok = Exchange.subscribe("ticket.42.pr.review_comment")

    review = %{
      "id" => 55_001,
      "state" => "CHANGES_REQUESTED",
      "body" => "this needs a test",
      "submitted_at" => "2026-06-24T12:00:00Z",
      "user" => %{"login" => "its-everdred"}
    }

    request_fun = fn %{url: url} ->
      if String.contains?(url, "/pulls/901/reviews") do
        {:ok, %{status: 200, body: [review]}}
      else
        {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 1}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: @repo,
               request_fun: request_fun,
               open_pull_requests_by_target: %{"42" => %{"number" => 901}},
               comment_batch: %{"42" => %{issue_comments: [], pr_issue_comments: [], review_thread_comments: []}}
             )

    polled = await_event("ticket.42.pr.review_comment")
    clear_dedup()

    delivery = %{
      "action" => "submitted",
      "repository" => %{"full_name" => @repo},
      "review" => review,
      "pull_request" => %{"number" => 901, "head" => %{"ref" => "aiur/42-some-slug", "sha" => "deadbeef"}},
      "sender" => %{"login" => "its-everdred"}
    }

    assert %{status: :published, published: ["ticket.42.pr.review_comment"]} =
             GithubWebhook.handle_delivery("pull_request_review", delivery, repo: @repo)

    pushed = await_event("ticket.42.pr.review_comment")

    assert_indistinguishable(polled, pushed)
  end

  test "pull request review comment: polling and webhook publish indistinguishable events" do
    :ok = Exchange.subscribe("ticket.42.pr.review_comment")

    comment = %{
      "id" => 7_007,
      "body" => "extract this into a helper",
      "created_at" => "2026-06-24T12:00:00Z",
      "updated_at" => "2026-06-24T12:00:00Z",
      "html_url" => "https://github.com/owner/repo/pull/901#discussion_r7007",
      "user" => %{"login" => "its-everdred"}
    }

    assert {:ok, %{count: 1}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: @repo,
               review_submission_targets: MapSet.new([]),
               open_pull_requests_by_target: %{"42" => %{"number" => 901}},
               comment_batch: %{
                 "42" => %{issue_comments: [], pr_issue_comments: [], review_thread_comments: [comment]}
               }
             )

    polled = await_event("ticket.42.pr.review_comment")
    clear_dedup()

    delivery = %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "comment" => comment,
      "pull_request" => %{"number" => 901, "head" => %{"ref" => "aiur/42-some-slug", "sha" => "deadbeef"}},
      "sender" => %{"login" => "its-everdred"}
    }

    assert %{status: :published, published: ["ticket.42.pr.review_comment"]} =
             GithubWebhook.handle_delivery("pull_request_review_comment", delivery, repo: @repo)

    pushed = await_event("ticket.42.pr.review_comment")

    assert_indistinguishable(polled, pushed)
  end

  # The two producers take `timestamp` from different places, so the fixture
  # deliberately gives them *different* values rather than one shared literal:
  # the firehose stamps the Events API envelope's `created_at`, and a webhook
  # body has no envelope, so the normalizer falls back to the pull request's own
  # `updated_at`. Making them equal in the fixture would hide that.
  #
  # Everything else must still match exactly. The gap is bounded — both describe
  # the same transition moments apart — and `RunTelemetry.Lifecycle` reads
  # `pr.created_at` / `pr.merged_at` ahead of `event.timestamp`, so the field is
  # a last-resort fallback for the one consumer that reads it at all.
  test "pull request opened: firehose and webhook publish indistinguishable events apart from timestamp source" do
    :ok = Exchange.subscribe("ticket.55.pr.opened")

    pr = %{
      "number" => 901,
      "title" => "W-3 webhooks",
      "created_at" => "2026-06-24T11:59:58Z",
      "updated_at" => "2026-06-24T11:59:59Z",
      "head" => %{"ref" => "aiur/55", "sha" => "deadbeef"}
    }

    firehose_event = %{
      "id" => "evt-1",
      "type" => "PullRequestEvent",
      "created_at" => "2026-06-24T12:00:00Z",
      "actor" => %{"login" => "its-everdred"},
      "repo" => %{"name" => @repo},
      "payload" => %{"action" => "opened", "pull_request" => pr}
    }

    stub = fn _request -> {:ok, %{status: 200, headers: [{"ETag", ~s("e1")}], body: [firehose_event]}} end

    assert {:ok, %{count: 1}} = GithubFirehose.poll(request_fun: stub, repo: @repo, boot_time: 0)

    polled = await_event("ticket.55.pr.opened")
    clear_dedup()

    delivery = %{
      "action" => "opened",
      "repository" => %{"full_name" => @repo},
      "pull_request" => pr,
      "sender" => %{"login" => "its-everdred"}
    }

    assert %{status: :published, published: ["ticket.55.pr.opened"]} =
             GithubWebhook.handle_delivery("pull_request", delivery, repo: @repo)

    pushed = await_event("ticket.55.pr.opened")

    # Each producer's documented source, with the fixture keeping them distinct.
    assert polled.timestamp == "2026-06-24T12:00:00Z"
    assert pushed.timestamp == "2026-06-24T11:59:59Z"

    # Everything a consumer routes, filters, or renders on is still identical —
    # including `pr`, `action`, the dedup key's inputs, and actor trust.
    assert Map.drop(polled, [:id, :ticket_observation, :timestamp]) ==
             Map.drop(pushed, [:id, :ticket_observation, :timestamp])
  end

  # `GET /pulls/N/reviews` reports `state` upper case; a `pull_request_review`
  # delivery reports it lower case. The earlier review-submission case uses one
  # shared review map, so it cannot see that. This one gives each producer its
  # real casing.
  test "realistic producer shapes: a lower-case delivery state is published as the poller's upper case" do
    :ok = Exchange.subscribe("ticket.42.pr.review_comment")

    polled_review = %{
      "id" => 55_003,
      "state" => "CHANGES_REQUESTED",
      "body" => "this needs a test",
      "submitted_at" => "2026-06-24T12:00:00Z",
      "user" => %{"login" => "its-everdred"}
    }

    request_fun = fn %{url: url} ->
      if String.contains?(url, "/pulls/901/reviews") do
        {:ok, %{status: 200, body: [polled_review]}}
      else
        {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 1}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: @repo,
               request_fun: request_fun,
               open_pull_requests_by_target: %{"42" => %{"number" => 901}},
               comment_batch: %{"42" => %{issue_comments: [], pr_issue_comments: [], review_thread_comments: []}}
             )

    polled = await_event("ticket.42.pr.review_comment")
    clear_dedup()

    delivery = %{
      "action" => "submitted",
      "repository" => %{"full_name" => @repo},
      "review" => %{polled_review | "state" => "changes_requested"},
      "pull_request" => %{"number" => 901, "head" => %{"ref" => "aiur/42-some-slug", "sha" => "deadbeef"}},
      "sender" => %{"login" => "its-everdred"}
    }

    assert %{status: :published, published: ["ticket.42.pr.review_comment"]} =
             GithubWebhook.handle_delivery("pull_request_review", delivery, repo: @repo)

    pushed = await_event("ticket.42.pr.review_comment")

    assert pushed.comment["state"] == "CHANGES_REQUESTED"
    assert_indistinguishable(polled, pushed)
  end

  # The cases above hand both producers the same comment map, which hides shape
  # drift: the poller never publishes GitHub's raw comment object, it publishes
  # `CommentPollBatch.normalize_comments/1` output. This case gives each producer
  # the shape it actually sees in production — a 6-key normalized comment for the
  # poller, GitHub's full REST object for the delivery — so the assertion is
  # about the normalizer rather than about the fixture.
  test "realistic producer shapes: a full REST delivery still matches the poller's normalized comment" do
    :ok = Exchange.subscribe("ticket.42.issue.commented")

    polled_comment = %{
      "id" => 1_001,
      "body" => "please rework this",
      "created_at" => "2026-06-24T12:00:00Z",
      "updated_at" => "2026-06-24T12:00:00Z",
      "html_url" => "https://github.com/owner/repo/issues/42#issuecomment-1001",
      "user" => %{"login" => "its-everdred"}
    }

    assert {:ok, %{count: 1}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: @repo,
               comment_batch: %{"42" => %{issue_comments: [polled_comment], open_pull_request: nil}}
             )

    polled = await_event("ticket.42.issue.commented")
    clear_dedup()

    # Everything GitHub actually puts on the wire, including the fields a
    # consumer would notice: node_id, reactions, author_association, and a full
    # user object rather than a bare login.
    delivery = %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "issue" => %{"number" => 42, "title" => "a ticket"},
      "sender" => %{"login" => "its-everdred"},
      "comment" => %{
        "id" => 1_001,
        "node_id" => "IC_kwDOabc123",
        "url" => "https://api.github.com/repos/owner/repo/issues/comments/1001",
        "html_url" => "https://github.com/owner/repo/issues/42#issuecomment-1001",
        "issue_url" => "https://api.github.com/repos/owner/repo/issues/42",
        "body" => "please rework this",
        "created_at" => "2026-06-24T12:00:00Z",
        "updated_at" => "2026-06-24T12:00:00Z",
        "author_association" => "COLLABORATOR",
        "performed_via_github_app" => nil,
        "reactions" => %{"url" => "https://api.github.com/x", "total_count" => 0, "+1" => 0},
        "user" => %{
          "login" => "its-everdred",
          "id" => 12_345,
          "node_id" => "U_kgDOabc",
          "avatar_url" => "https://avatars.githubusercontent.com/u/12345?v=4",
          "type" => "User",
          "site_admin" => false,
          "url" => "https://api.github.com/users/its-everdred"
        }
      }
    }

    assert %{status: :published, published: ["ticket.42.issue.commented"]} =
             GithubWebhook.handle_delivery("issue_comment", delivery, repo: @repo)

    pushed = await_event("ticket.42.issue.commented")

    # The delivery's extra fields must not reach consumers, and `user` must be
    # the bare login the poller publishes.
    assert Map.keys(pushed.comment) |> Enum.sort() == Map.keys(polled.comment) |> Enum.sort()
    assert pushed.comment["user"] == %{"login" => "its-everdred"}
    assert_indistinguishable(polled, pushed)
  end

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
    %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "comment" => comment,
      "pull_request" => %{"number" => 901, "head" => %{"ref" => "aiur/42-some-slug", "sha" => "deadbeef"}},
      "sender" => %{"login" => "its-everdred"}
    }
  end

  defp thread_resolver(thread_id) do
    fn _request ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "node" => %{"pullRequestReviewThread" => %{"id" => thread_id}}
           }
         }
       }}
    end
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
    :ok = Exchange.subscribe("ticket.42.pr.review_comment")

    polled_comment = thread_comment()

    assert {:ok, %{count: 1}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: @repo,
               review_submission_targets: MapSet.new([]),
               open_pull_requests_by_target: %{"42" => %{"number" => 901}},
               comment_batch: %{
                 "42" => %{issue_comments: [], pr_issue_comments: [], review_thread_comments: [polled_comment]}
               }
             )

    assert_receive {:event, %{topic: "ticket.42.pr.review_comment", comment: %{"review_thread_id" => @thread_id}}},
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
    refute_receive {:event, %{topic: "ticket.42.pr.review_comment"}}, 200
  end

  test "a review thread comment delivered by webhook is not re-published by the poll" do
    :ok = Exchange.subscribe("ticket.42.pr.review_comment")

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

    assert %{status: :published, published: ["ticket.42.pr.review_comment"]} =
             GithubWebhook.handle_delivery("pull_request_review_comment", thread_comment_delivery(comment),
               repo: @repo,
               request_fun: thread_resolver(@thread_id)
             )

    assert_receive {:event, %{topic: "ticket.42.pr.review_comment", comment: %{"review_thread_id" => @thread_id}}},
                   500

    # The reconciliation poll then reads the same thread. The in-memory replay
    # window is cleared first so the durable resource mark — `{:pr_review_thread,
    # owner, repo, thread_id}` written by both pipes — is the only thing left
    # suppressing the re-publish. That is the restart-proof half of the seam.
    clear_replay_window()
    thread = Map.put(comment, "review_thread_id", @thread_id)

    assert {:ok, %{count: 0}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: @repo,
               review_submission_targets: MapSet.new([]),
               open_pull_requests_by_target: %{"42" => %{"number" => 901}},
               comment_batch: %{
                 "42" => %{issue_comments: [], pr_issue_comments: [], review_thread_comments: [thread]}
               }
             )

    refute_receive {:event, %{topic: "ticket.42.pr.review_comment"}}, 200
  end

  # Acceptance criterion 4, and the half of the change a reviewer must evaluate
  # (the issue's requirement 4): a reviewer adding several comments to one
  # thread wakes the agent once, not once per comment. This is the webhook's
  # previous behaviour, now changed — before #2081 a second comment on the same
  # thread was a distinct per-comment key and woke again.
  test "several comments on one review thread produce one agent wake" do
    :ok = Exchange.subscribe("ticket.42.pr.review_comment")

    first = comment_on_thread(7_007, "2026-06-24T12:00:00Z")
    second = comment_on_thread(7_008, "2026-06-24T12:05:00Z")

    # First comment wakes the agent once...
    assert %{status: :published, published: ["ticket.42.pr.review_comment"]} =
             GithubWebhook.handle_delivery("pull_request_review_comment", thread_comment_delivery(first),
               repo: @repo,
               request_fun: thread_resolver(@thread_id)
             )

    assert_receive {:event, %{topic: "ticket.42.pr.review_comment", comment: %{"id" => 7_007}}}, 500

    # ...a follow-up comment on the same thread within the replay window does
    # not wake a second time. Newer `updated_at`, so only the thread key — not
    # the resource version — is what suppresses it.
    assert %{status: :published, published: []} =
             GithubWebhook.handle_delivery("pull_request_review_comment", thread_comment_delivery(second),
               repo: @repo,
               request_fun: thread_resolver(@thread_id)
             )

    refute_receive {:event, %{topic: "ticket.42.pr.review_comment"}}, 200
  end

  # The fail-open degradation, pinned deliberately. Thread granularity is the
  # chosen behaviour, but resolving the thread needs the delivered comment's
  # `node_id` and a working lookup; when either is missing the webhook falls
  # back to per-comment keying — exactly the pre-#2081 behaviour, divergence
  # included. That is the safe direction: a duplicate wake is recoverable, a
  # dropped delivery is not, so a failure must cost a possible extra wake, never
  # a lost comment.
  test "an unresolvable review thread delivery falls back to per-comment keying" do
    :ok = Exchange.subscribe("ticket.42.pr.review_comment")

    # No `node_id`, so the resolver is never consulted and the delivery keys per
    # comment, as before #2081.
    delivery =
      thread_comment_delivery(thread_comment() |> Map.delete("review_thread_id"))

    assert %{status: :published, published: ["ticket.42.pr.review_comment"]} =
             GithubWebhook.handle_delivery("pull_request_review_comment", delivery, repo: @repo)

    assert_receive {:event, %{topic: "ticket.42.pr.review_comment"} = event}, 500
    refute Map.has_key?(event.comment, "review_thread_id")
  end

  test "the same event seen by both producers wakes a consumer exactly once" do
    :ok = Exchange.subscribe("ticket.42.issue.commented")

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
      "issue" => %{"number" => 42},
      "comment" => comment,
      "sender" => %{"login" => "its-everdred"}
    }

    assert %{status: :published, published: ["ticket.42.issue.commented"]} =
             GithubWebhook.handle_delivery("issue_comment", delivery, repo: @repo)

    assert_receive {:event, %{topic: "ticket.42.issue.commented"}}, 500

    # The reconciliation poll then sees the same comment. Sharing the poller's
    # dedup key is what keeps this from becoming a second wake.
    assert {:ok, %{count: 0}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: @repo,
               comment_batch: %{"42" => %{issue_comments: [comment], open_pull_request: nil}}
             )

    refute_receive {:event, %{topic: "ticket.42.issue.commented"}}, 200
  end

  # Known divergence, pinned deliberately. `reviewDecision` is a GraphQL field,
  # so no webhook delivery can carry it. On an APPROVED pull request the poller's
  # batch path publishes it and `ReviewFreshness` suppresses rework; the webhook
  # path publishes nil and the same GitHub event routes the ticket to rework.
  #
  # W-3 makes the webhook the primary path, so this is the gate in #1756 losing
  # its approved-PR half in the common case. Closing it needs a GraphQL fetch in
  # the delivery path (the W-1 receiver's request path, and W-4's ordering work),
  # which is why it is reported rather than absorbed here.
  #
  # If someone adds that fetch, this test fails and must be rewritten as a plain
  # `assert_indistinguishable/2` case. That failure is the point.
  test "known divergence: review_decision cannot ride on a delivery, and consumers can tell" do
    :ok = Exchange.subscribe("ticket.42.pr.review_comment")

    review = %{
      "id" => 55_002,
      "state" => "COMMENTED",
      "body" => "one nitpick on an already-approved PR",
      "submitted_at" => "2026-06-24T12:00:00Z",
      "user" => %{"login" => "its-everdred"}
    }

    request_fun = fn %{url: url} ->
      if String.contains?(url, "/pulls/901/reviews") do
        {:ok, %{status: 200, body: [review]}}
      else
        {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 1}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: @repo,
               request_fun: request_fun,
               open_pull_requests_by_target: %{
                 "42" => %{"number" => 901, "review_decision" => "APPROVED", "head_committed_at" => "2026-06-24T10:00:00Z"}
               },
               comment_batch: %{"42" => %{issue_comments: [], pr_issue_comments: [], review_thread_comments: []}}
             )

    polled = await_event("ticket.42.pr.review_comment")
    clear_dedup()

    delivery = %{
      "action" => "submitted",
      "repository" => %{"full_name" => @repo},
      "review" => review,
      "pull_request" => %{"number" => 901, "head" => %{"ref" => "aiur/42-some-slug", "sha" => "deadbeef"}},
      "sender" => %{"login" => "its-everdred"}
    }

    assert %{status: :published, published: ["ticket.42.pr.review_comment"]} =
             GithubWebhook.handle_delivery("pull_request_review", delivery, repo: @repo)

    pushed = await_event("ticket.42.pr.review_comment")

    # The payloads differ in exactly one key, and only in the GraphQL-only half.
    assert %{"review_decision" => "APPROVED"} = polled.pull_request
    assert %{"review_decision" => nil} = pushed.pull_request
    assert Map.drop(polled, [:id, :ticket_observation, :pull_request]) == Map.drop(pushed, [:id, :ticket_observation, :pull_request])

    # And the difference is consumer-visible: the same GitHub event suppresses
    # rework on one path and triggers it on the other.
    assert ReviewFreshness.rework_skip_reason(polled) == :approved_pull_request
    assert ReviewFreshness.rework_skip_reason(pushed) == nil
  end

  defp assert_indistinguishable(polled, pushed) do
    volatile = [:id, :ticket_observation]

    assert Map.drop(polled, volatile) == Map.drop(pushed, volatile),
           """
           webhook and polling payloads diverge

           only in polling: #{inspect(Map.drop(polled, volatile) |> Map.drop(Map.keys(Map.drop(pushed, volatile))))}
           only in webhook: #{inspect(Map.drop(pushed, volatile) |> Map.drop(Map.keys(Map.drop(polled, volatile))))}

           polling: #{inspect(Map.drop(polled, volatile), pretty: true)}
           webhook: #{inspect(Map.drop(pushed, volatile), pretty: true)}
           """
  end

  defp await_event(topic) do
    receive do
      {:event, %{topic: ^topic} = event} -> event
    after
      1_000 -> flunk("no event published on #{topic}")
    end
  end

  # Empties only the volatile replay window, leaving the durable resource marks
  # in place — the state a daemon restart actually produces.
  defp clear_replay_window do
    case :ets.whereis(@dedup_table) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end

    :ok
  end

  # These tests deliberately drive both pipes over the *same* comment so the two
  # published events can be compared field by field. In production that second
  # publish is exactly what must not happen — it is the double-processing #2069
  # removes — so every suppression layer has to be cleared between the halves,
  # not just the in-memory window.
  defp clear_dedup do
    case :ets.whereis(@dedup_table) do
      :undefined -> :ok
      _table -> :ets.delete_all_objects(@dedup_table)
    end

    ResourceStore.reset()

    :ok
  end
end

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

  use Aiur.TestSupport.WebhookEquivalenceFixture

  alias Aiur.Events.{Exchange, GithubCommentsPoller, GithubFirehose, GithubWebhook}
  alias Aiur.Orchestrator.ReviewFreshness

  @repo "owner/repo"

  test "issue comment: polling and webhook publish indistinguishable events" do
    ticket = ticket_id()
    number = ticket_number()
    fixture_topic0 = "ticket.#{ticket}.issue.commented"
    fixture_value1 = "https://github.com/owner/repo/issues/#{ticket}#issuecomment-1001"
    :ok = Exchange.subscribe(fixture_topic0)

    # `html_url` is present because `CommentPollBatch.normalize_comments/1`
    # always emits it; a fixture without it is a shape the poller never produces.
    comment = %{
      "id" => 1_001,
      "body" => "please rework this",
      "created_at" => "2026-06-24T12:00:00Z",
      "updated_at" => "2026-06-24T12:00:00Z",
      "html_url" => fixture_value1,
      "user" => %{"login" => "its-everdred"}
    }

    assert {:ok, %{count: 1}} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: @repo,
               comment_batch: %{ticket => %{issue_comments: [comment], open_pull_request: nil}}
             )

    polled = await_event(fixture_topic0)
    clear_dedup()

    delivery = %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "issue" => %{"number" => number, "title" => "a ticket"},
      "comment" => comment,
      "sender" => %{"login" => "its-everdred"}
    }

    assert %{status: :published, published: [^fixture_topic0]} =
             GithubWebhook.handle_delivery("issue_comment", delivery, repo: @repo)

    pushed = await_event(fixture_topic0)

    assert_indistinguishable(polled, pushed)
  end

  test "pull request review submission: polling and webhook publish indistinguishable events" do
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
    fixture_value2 = "aiur/#{ticket}-some-slug"
    :ok = Exchange.subscribe(fixture_topic0)

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
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: @repo,
               request_fun: request_fun,
               open_pull_requests_by_target: %{ticket => %{"number" => 901}},
               comment_batch: %{ticket => %{issue_comments: [], pr_issue_comments: [], review_thread_comments: []}}
             )

    polled = await_event(fixture_topic0)
    clear_dedup()

    delivery = %{
      "action" => "submitted",
      "repository" => %{"full_name" => @repo},
      "review" => review,
      "pull_request" => %{"number" => 901, "head" => %{"ref" => fixture_value2, "sha" => "deadbeef"}},
      "sender" => %{"login" => "its-everdred"}
    }

    assert %{status: :published, published: [^fixture_topic0]} =
             GithubWebhook.handle_delivery("pull_request_review", delivery, repo: @repo)

    pushed = await_event(fixture_topic0)

    assert_indistinguishable(polled, pushed)
  end

  test "pull request review comment: polling and webhook publish indistinguishable events" do
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
    fixture_value2 = "aiur/#{ticket}-some-slug"
    :ok = Exchange.subscribe(fixture_topic0)

    comment = %{
      "id" => 7_007,
      "body" => "extract this into a helper",
      "created_at" => "2026-06-24T12:00:00Z",
      "updated_at" => "2026-06-24T12:00:00Z",
      "html_url" => "https://github.com/owner/repo/pull/901#discussion_r7007",
      "user" => %{"login" => "its-everdred"}
    }

    assert {:ok, %{count: 1}} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: @repo,
               review_submission_targets: MapSet.new([]),
               open_pull_requests_by_target: %{ticket => %{"number" => 901}},
               comment_batch: %{
                 ticket => %{issue_comments: [], pr_issue_comments: [], review_thread_comments: [comment]}
               }
             )

    polled = await_event(fixture_topic0)
    clear_dedup()

    delivery = %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "comment" => comment,
      "pull_request" => %{"number" => 901, "head" => %{"ref" => fixture_value2, "sha" => "deadbeef"}},
      "sender" => %{"login" => "its-everdred"}
    }

    assert %{status: :published, published: [^fixture_topic0]} =
             GithubWebhook.handle_delivery("pull_request_review_comment", delivery, repo: @repo)

    pushed = await_event(fixture_topic0)

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
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
    fixture_value2 = "aiur/#{ticket}-some-slug"
    :ok = Exchange.subscribe(fixture_topic0)

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
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: @repo,
               request_fun: request_fun,
               open_pull_requests_by_target: %{ticket => %{"number" => 901}},
               comment_batch: %{ticket => %{issue_comments: [], pr_issue_comments: [], review_thread_comments: []}}
             )

    polled = await_event(fixture_topic0)
    clear_dedup()

    delivery = %{
      "action" => "submitted",
      "repository" => %{"full_name" => @repo},
      "review" => %{polled_review | "state" => "changes_requested"},
      "pull_request" => %{"number" => 901, "head" => %{"ref" => fixture_value2, "sha" => "deadbeef"}},
      "sender" => %{"login" => "its-everdred"}
    }

    assert %{status: :published, published: [^fixture_topic0]} =
             GithubWebhook.handle_delivery("pull_request_review", delivery, repo: @repo)

    pushed = await_event(fixture_topic0)

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
    ticket = ticket_id()
    number = ticket_number()
    fixture_topic0 = "ticket.#{ticket}.issue.commented"
    fixture_value1 = "https://github.com/owner/repo/issues/#{ticket}#issuecomment-1001"
    fixture_value4 = "https://api.github.com/repos/owner/repo/issues/#{ticket}"
    :ok = Exchange.subscribe(fixture_topic0)

    polled_comment = %{
      "id" => 1_001,
      "body" => "please rework this",
      "created_at" => "2026-06-24T12:00:00Z",
      "updated_at" => "2026-06-24T12:00:00Z",
      "html_url" => fixture_value1,
      "user" => %{"login" => "its-everdred"}
    }

    assert {:ok, %{count: 1}} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: @repo,
               comment_batch: %{ticket => %{issue_comments: [polled_comment], open_pull_request: nil}}
             )

    polled = await_event(fixture_topic0)
    clear_dedup()

    # Everything GitHub actually puts on the wire, including the fields a
    # consumer would notice: node_id, reactions, author_association, and a full
    # user object rather than a bare login.
    delivery = %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "issue" => %{"number" => number, "title" => "a ticket"},
      "sender" => %{"login" => "its-everdred"},
      "comment" => %{
        "id" => 1_001,
        "node_id" => "IC_kwDOabc123",
        "url" => "https://api.github.com/repos/owner/repo/issues/comments/1001",
        "html_url" => fixture_value1,
        "issue_url" => fixture_value4,
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

    assert %{status: :published, published: [^fixture_topic0]} =
             GithubWebhook.handle_delivery("issue_comment", delivery, repo: @repo)

    pushed = await_event(fixture_topic0)

    # The delivery's extra fields must not reach consumers, and `user` must be
    # the bare login the poller publishes.
    assert Map.keys(pushed.comment) |> Enum.sort() == Map.keys(polled.comment) |> Enum.sort()
    assert pushed.comment["user"] == %{"login" => "its-everdred"}
    assert_indistinguishable(polled, pushed)
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
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
    fixture_value2 = "aiur/#{ticket}-some-slug"
    :ok = Exchange.subscribe(fixture_topic0)

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
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: @repo,
               request_fun: request_fun,
               open_pull_requests_by_target: %{
                 ticket => %{"number" => 901, "review_decision" => "APPROVED", "head_committed_at" => "2026-06-24T10:00:00Z"}
               },
               comment_batch: %{ticket => %{issue_comments: [], pr_issue_comments: [], review_thread_comments: []}}
             )

    polled = await_event(fixture_topic0)
    clear_dedup()

    delivery = %{
      "action" => "submitted",
      "repository" => %{"full_name" => @repo},
      "review" => review,
      "pull_request" => %{"number" => 901, "head" => %{"ref" => fixture_value2, "sha" => "deadbeef"}},
      "sender" => %{"login" => "its-everdred"}
    }

    assert %{status: :published, published: [^fixture_topic0]} =
             GithubWebhook.handle_delivery("pull_request_review", delivery, repo: @repo)

    pushed = await_event(fixture_topic0)

    # The payloads differ in exactly one key, and only in the GraphQL-only half.
    assert %{"review_decision" => "APPROVED"} = polled.pull_request
    assert %{"review_decision" => nil} = pushed.pull_request
    assert Map.drop(polled, [:id, :ticket_observation, :pull_request]) == Map.drop(pushed, [:id, :ticket_observation, :pull_request])

    # And the difference is consumer-visible: the same GitHub event suppresses
    # rework on one path and triggers it on the other.
    assert ReviewFreshness.rework_skip_reason(polled) == :approved_pull_request
    assert ReviewFreshness.rework_skip_reason(pushed) == nil
  end
end

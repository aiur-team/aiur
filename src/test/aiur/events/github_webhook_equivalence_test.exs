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

  Two known divergences are pinned rather than asserted away, both rooted in the
  same cause — GraphQL-only values that no webhook delivery can carry:

    * `review_decision`, which changes whether `ReviewFreshness` suppresses
      rework on an APPROVED pull request.
    * `review_thread_id`, which changes the dedup key for review thread comments
      so the two producers wake the agent twice for one comment.

  Each has a test asserting the current divergent behaviour. When either is
  fixed, its test fails and must be rewritten as an equivalence or coalescing
  assertion — that failure is the tripwire.
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

  # Known divergence, pinned deliberately — the counterexample to the test above.
  #
  # Coalescing holds only where both producers derive the same dedup key. For
  # review *thread* comments they do not. The GraphQL batch path stamps every
  # thread comment with `review_thread_id` (`ReviewThreads.normalize_thread_comment/2`,
  # from the thread node id), so the poller keys on
  # `{repo, "pr_review_thread:901", "PRRT_..."}` while a delivery — which carries
  # no GraphQL node id — can only key on `{repo, "pr_review_comment:901", "7007"}`.
  #
  # Different keys means the Publisher window never collapses them: the webhook
  # wakes the agent, the reconciliation poll wakes it again for the same comment.
  # The two are also semantically different policies — the poller dedups per
  # *thread*, the webhook per *comment* — so this is a choice, not just a
  # missing field, and it is not closable in the normalizer.
  #
  # The earlier review-comment equivalence case passes only because it injects a
  # comment with no `review_thread_id`, which takes the poller's fallback branch.
  # This case uses the shape the batch actually produces.
  test "known divergence: review thread comments do not coalesce and wake twice" do
    :ok = Exchange.subscribe("ticket.42.pr.review_comment")

    polled_comment = %{
      "id" => 7_007,
      "review_thread_id" => "PRRT_kwDOabc123",
      "body" => "extract this into a helper",
      "created_at" => "2026-06-24T12:00:00Z",
      "updated_at" => "2026-06-24T12:00:00Z",
      "html_url" => "https://github.com/owner/repo/pull/901#discussion_r7007",
      "path" => "lib/foo.ex",
      "line" => 12,
      "user" => %{"login" => "its-everdred"}
    }

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

    assert_receive {:event, %{topic: "ticket.42.pr.review_comment"}}, 500

    # Dedup deliberately NOT cleared: if the keys agreed, this publish would be
    # suppressed as a duplicate the way the issue-comment case above is.
    delivery = %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "comment" => Map.delete(polled_comment, "review_thread_id"),
      "pull_request" => %{"number" => 901, "head" => %{"ref" => "aiur/42-some-slug", "sha" => "deadbeef"}},
      "sender" => %{"login" => "its-everdred"}
    }

    assert %{status: :published, published: ["ticket.42.pr.review_comment"]} =
             GithubWebhook.handle_delivery("pull_request_review_comment", delivery, repo: @repo)

    # The second wake. When this stops arriving, the divergence is fixed and this
    # test must be rewritten as a coalescing assertion.
    assert_receive {:event, %{topic: "ticket.42.pr.review_comment"}}, 500
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

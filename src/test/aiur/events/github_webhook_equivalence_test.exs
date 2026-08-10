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

  The one known exception is `review_decision`, which is GraphQL-only and so
  cannot ride on any delivery. The last test pins that divergence and the
  consumer-visible behaviour difference it produces, so the gap stays visible
  and cannot widen unnoticed.
  """

  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, GithubCommentsPoller, GithubFirehose, GithubWebhook, Publisher}
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

    comment = %{
      "id" => 1_001,
      "body" => "please rework this",
      "created_at" => "2026-06-24T12:00:00Z",
      "updated_at" => "2026-06-24T12:00:00Z",
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

  test "pull request opened: firehose and webhook publish indistinguishable events" do
    :ok = Exchange.subscribe("ticket.55.pr.opened")

    pr = %{
      "number" => 901,
      "title" => "W-3 webhooks",
      "updated_at" => "2026-06-24T12:00:00Z",
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

    assert_indistinguishable(polled, pushed)
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

  defp clear_dedup do
    case :ets.whereis(@dedup_table) do
      :undefined -> :ok
      _table -> :ets.delete_all_objects(@dedup_table)
    end

    :ok
  end
end

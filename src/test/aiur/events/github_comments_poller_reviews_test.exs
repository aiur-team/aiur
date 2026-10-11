defmodule Aiur.Events.GithubCommentsPollerReviewsTest do
  use Aiur.TestSupport
  use Aiur.TestSupport.EventTicket
  import Aiur.TestSupport.CommentsPollerFixture

  alias Aiur.Events.Exchange
  alias Aiur.Events.GithubCommentsPoller

  setup :comments_poller_env

  describe "PR review submission polling" do
    test "publishes pr.review_comment for CHANGES_REQUESTED from a trusted reviewer" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)
      codeowners = ensure_codeowners!("* @its-everdred\n")

      review = pr_review(9_001, "its-everdred", "CHANGES_REQUESTED", "please rework this section")

      assert {:ok, %{count: 1, errors: []}} =
               GithubCommentsPoller.poll([ticket],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([review])
               )

      assert_receive {:event,
                      %{
                        topic: ^fixture_topic0,
                        author_trusted?: true,
                        source: :github,
                        comment: %{
                          "state" => "CHANGES_REQUESTED",
                          "body" => "please rework this section"
                        }
                      }},
                     500

      stop_codeowners(codeowners)
    end

    # #1756: the orchestrator's rework gate is a pure function over the event,
    # so the review decision and head commit date the batch resolved have to
    # ride along on every published PR comment and review event.
    test "carries the pull request review context onto published review events" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)
      codeowners = ensure_codeowners!("* @its-everdred\n")

      review = pr_review(9_010, "its-everdred", "CHANGES_REQUESTED", "please rework this section")

      batch = %{
        ticket => %{
          open_pull_request: %{
            "number" => 77,
            "review_decision" => "CHANGES_REQUESTED",
            "head_committed_at" => "2026-08-10T04:29:00Z"
          },
          issue_comments: [],
          pr_issue_comments: [],
          review_thread_comments: []
        }
      }

      assert {:ok, %{count: 1, errors: []}} =
               GithubCommentsPoller.poll([ticket],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 comment_batch: batch,
                 request_fun: request_fun_with_reviews([review])
               )

      assert_receive {:event,
                      %{
                        topic: ^fixture_topic0,
                        pull_request: %{
                          "review_decision" => "CHANGES_REQUESTED",
                          "head_committed_at" => "2026-08-10T04:29:00Z"
                        }
                      }},
                     500

      stop_codeowners(codeowners)
    end

    test "publishes pr.review_comment for COMMENTED from a trusted reviewer" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)
      codeowners = ensure_codeowners!("* @its-everdred\n")

      review = pr_review(9_002, "its-everdred", "COMMENTED", "left some thoughts in review body")

      assert {:ok, %{count: 1, errors: []}} =
               GithubCommentsPoller.poll([ticket],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([review])
               )

      assert_receive {:event,
                      %{
                        topic: ^fixture_topic0,
                        author_trusted?: true,
                        source: :github,
                        comment: %{"state" => "COMMENTED"}
                      }},
                     500

      stop_codeowners(codeowners)
    end

    test "publishes pr.review_comment with author_trusted? false for untrusted reviewer" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)
      codeowners = ensure_codeowners!("* @its-everdred\n")

      review = pr_review(9_003, "outsider", "CHANGES_REQUESTED", "some feedback")

      assert {:ok, %{count: 1, errors: []}} =
               GithubCommentsPoller.poll([ticket],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([review])
               )

      assert_receive {:event,
                      %{
                        topic: ^fixture_topic0,
                        author_trusted?: false
                      }},
                     500

      stop_codeowners(codeowners)
    end

    test "does not publish pr.review_comment for APPROVED review" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)
      codeowners = ensure_codeowners!("* @its-everdred\n")

      review = pr_review(9_004, "its-everdred", "APPROVED", "lgtm")

      assert {:ok, %{count: 0, errors: []}} =
               GithubCommentsPoller.poll([ticket],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([review])
               )

      refute_receive {:event, %{topic: ^fixture_topic0}}, 100
      stop_codeowners(codeowners)
    end

    test "does not publish pr.review_comment for DISMISSED review" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)
      codeowners = ensure_codeowners!("* @its-everdred\n")

      review = pr_review(9_005, "its-everdred", "DISMISSED", "")

      assert {:ok, %{count: 0, errors: []}} =
               GithubCommentsPoller.poll([ticket],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([review])
               )

      refute_receive {:event, %{topic: ^fixture_topic0}}, 100
      stop_codeowners(codeowners)
    end

    test "publishes only the most recent review per reviewer when multiple exist" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)
      codeowners = ensure_codeowners!("* @its-everdred\n")

      older = pr_review(9_006, "its-everdred", "COMMENTED", "first pass", "2026-06-24T10:00:00Z")

      newer =
        pr_review(
          9_007,
          "its-everdred",
          "CHANGES_REQUESTED",
          "second pass",
          "2026-06-24T12:00:00Z"
        )

      assert {:ok, %{count: 1, errors: []}} =
               GithubCommentsPoller.poll([ticket],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([older, newer])
               )

      assert_receive {:event,
                      %{
                        topic: ^fixture_topic0,
                        comment: %{"id" => 9_007, "state" => "CHANGES_REQUESTED"}
                      }},
                     500

      refute_receive {:event, %{topic: ^fixture_topic0}}, 100
      stop_codeowners(codeowners)
    end

    test "does not publish pr.review_comment when reviewer's latest is APPROVED after CHANGES_REQUESTED" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)
      codeowners = ensure_codeowners!("* @its-everdred\n")

      older =
        pr_review(
          9_010,
          "its-everdred",
          "CHANGES_REQUESTED",
          "please fix",
          "2026-06-24T10:00:00Z"
        )

      newer =
        pr_review(9_011, "its-everdred", "APPROVED", "lgtm after fixes", "2026-06-24T14:00:00Z")

      assert {:ok, %{count: 0, errors: []}} =
               GithubCommentsPoller.poll([ticket],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([older, newer])
               )

      refute_receive {:event, %{topic: ^fixture_topic0}}, 100
      stop_codeowners(codeowners)
    end

    test "a later blank-bodied COMMENTED container does not mask an earlier CHANGES_REQUESTED" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)
      codeowners = ensure_codeowners!("* @its-everdred\n")

      changes_requested =
        pr_review(
          9_012,
          "its-everdred",
          "CHANGES_REQUESTED",
          "please fix",
          "2026-06-24T12:00:00Z"
        )

      # GitHub wraps a later inline-only comment in an empty-bodied COMMENTED
      # review. It must be transparent, not the reviewer's "most recent".
      inline_container = pr_review(9_013, "its-everdred", "COMMENTED", "", "2026-06-24T13:00:00Z")

      assert {:ok, %{count: 1, errors: []}} =
               GithubCommentsPoller.poll([ticket],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([changes_requested, inline_container])
               )

      assert_receive {:event,
                      %{
                        topic: ^fixture_topic0,
                        comment: %{"id" => 9_012, "state" => "CHANGES_REQUESTED"}
                      }},
                     500

      refute_receive {:event, %{topic: ^fixture_topic0}}, 100
      stop_codeowners(codeowners)
    end

    test "publishes one review per reviewer when multiple trusted reviewers" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)
      codeowners = ensure_codeowners!("* @its-everdred @other-reviewer\n")

      review_a = pr_review(9_008, "its-everdred", "CHANGES_REQUESTED", "feedback from A")
      review_b = pr_review(9_009, "other-reviewer", "CHANGES_REQUESTED", "feedback from B")

      assert {:ok, %{count: 2, errors: []}} =
               GithubCommentsPoller.poll([ticket],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([review_a, review_b])
               )

      assert_receive {:event, %{topic: ^fixture_topic0, comment: %{"id" => 9_008}}},
                     500

      assert_receive {:event, %{topic: ^fixture_topic0, comment: %{"id" => 9_009}}},
                     500

      stop_codeowners(codeowners)
    end

    test "deduplicates PR review submissions on repeated polls" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)
      codeowners = ensure_codeowners!("* @its-everdred\n")

      review = pr_review(9_020, "its-everdred", "CHANGES_REQUESTED", "please rework")

      assert {:ok, %{count: 1, errors: []}} =
               GithubCommentsPoller.poll([ticket],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([review])
               )

      assert_receive {:event, %{topic: ^fixture_topic0, comment: %{"id" => 9_020}}},
                     500

      assert {:ok, %{count: 0, errors: []}} =
               GithubCommentsPoller.poll([ticket],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun_with_reviews([review])
               )

      refute_receive {:event, %{topic: ^fixture_topic0}}, 100
      stop_codeowners(codeowners)
    end

    # #2601: the aggregate `reviewDecision` is already `CHANGES_REQUESTED` when
    # the second review lands, and both reviews are body-only from the same
    # reviewer with the same state — so nothing about the *aggregate* changed.
    # The publish has to be edge-triggered on the review's own identity and
    # `submitted_at` instead, and re-polling the same pair afterwards has to
    # stay silent.
    test "publishes a second body-only CHANGES_REQUESTED review on a later head" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)
      codeowners = ensure_codeowners!("* @its-everdred\n")

      first_head_review = pr_review(9_040, "its-everdred", "CHANGES_REQUESTED", "first pass", "2026-09-10T00:10:30Z")
      second_head_review = pr_review(9_041, "its-everdred", "CHANGES_REQUESTED", "still not right", "2026-09-10T00:46:36Z")

      poll = fn reviews, seen_at ->
        GithubCommentsPoller.poll([ticket],
          since: "2026-09-10T00:00:00Z",
          repo: "owner/repo",
          pr_review_seen_at: seen_at,
          request_fun: request_fun_with_reviews(reviews)
        )
      end

      assert {:ok, %{count: 1, errors: [], pr_review_seen_at: after_first}} = poll.([first_head_review], %{})
      assert_receive {:event, %{topic: ^fixture_topic0, comment: %{"id" => 9_040}}}, 500
      assert after_first == %{ticket => "2026-09-10T00:10:30Z"}

      # The rework turn finished on a new head and the reviewer submitted again.
      assert {:ok, %{count: 1, errors: [], pr_review_seen_at: after_second}} =
               poll.([first_head_review, second_head_review], after_first)

      assert_receive {:event, %{topic: ^fixture_topic0, comment: %{"id" => 9_041}}}, 500
      assert after_second == %{ticket => "2026-09-10T00:46:36Z"}

      # Redelivery of the identical pair is a no-op.
      assert {:ok, %{count: 0, errors: []}} = poll.([first_head_review, second_head_review], after_second)
      refute_receive {:event, %{topic: ^fixture_topic0}}, 100

      stop_codeowners(codeowners)
    end

    test "blank-bodied COMMENTED reviews are not published (avoid double-wake for inline-only reviews)" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      # GitHub creates an empty COMMENTED review as the container for inline
      # comments. Those inline comments are already published via review threads;
      # publishing the blank container too would double-wake the agent.
      :ok = Exchange.subscribe(fixture_topic0)
      codeowners = ensure_codeowners!("* @its-everdred\n")

      blank_commented = pr_review(9_030, "its-everdred", "COMMENTED", "")

      request_fun = request_fun_with_reviews([blank_commented])

      assert {:ok, %{count: 0, errors: []}} =
               GithubCommentsPoller.poll([ticket],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun
               )

      refute_receive {:event, %{topic: ^fixture_topic0}}, 100
      stop_codeowners(codeowners)
    end

    test "COMMENTED review with a body is published" do
      ticket = ticket_id()
      fixture_topic0 = "ticket.#{ticket}.pr.review_comment"
      :ok = Exchange.subscribe(fixture_topic0)
      codeowners = ensure_codeowners!("* @its-everdred\n")

      commented_with_body = pr_review(9_032, "its-everdred", "COMMENTED", "minor nit: fix the spacing")

      request_fun = request_fun_with_reviews([commented_with_body])

      assert {:ok, %{count: 1, errors: []}} =
               GithubCommentsPoller.poll([ticket],
                 since: "2026-06-24T11:00:00Z",
                 repo: "owner/repo",
                 request_fun: request_fun
               )

      assert_receive {:event, %{topic: ^fixture_topic0, comment: %{"id" => 9_032}}}, 500
      stop_codeowners(codeowners)
    end
  end
end

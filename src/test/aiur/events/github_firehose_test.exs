defmodule Aiur.Events.GithubFirehoseTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, GithubFirehose, Publisher}
  alias Aiur.Workflow

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur"
    )

    # Persistent_term outlives test boundaries; reset before each test.
    Publisher.set_tracked_fn(fn _ -> true end)

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)
      Publisher.set_tracked_fn(fn _ -> true end)

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end)

    :ok
  end

  describe "poll/1" do
    test "PushEvent on ticket branch publishes ticket.<id>.branch.push" do
      :ok = Exchange.subscribe("ticket.42.branch.push")

      stub = fn _req ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("e1")}, {"X-Poll-Interval", "60"}],
           body: [
             %{
               "type" => "PushEvent",
               "actor" => %{"login" => "alice"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "ref" => "refs/heads/aiur/42",
                 "head" => "abc-#{System.unique_integer([:positive])}",
                 "commits" => [%{"message" => "wip"}]
               }
             }
           ]
         }}
      end

      assert {:ok, %{etag: ~s("e1"), count: 1}} = GithubFirehose.poll(request_fun: stub)
      assert_receive {:event, %{topic: "ticket.42.branch.push", actor: "alice"}}, 500
    end

    test "304 returns previously-cached etag, no publishes" do
      :ok = Exchange.subscribe("ticket.42.#")

      stub = fn %{etag: ~s("e1")} ->
        {:ok, %{status: 304, headers: [{"ETag", ~s("e1")}], body: ""}}
      end

      assert {:ok, %{etag: ~s("e1"), count: 0}} =
               GithubFirehose.poll(etag: ~s("e1"), request_fun: stub)

      refute_receive {:event, _}, 100
    end

    test "PushEvent on default branch publishes system.<branch>.branch.push" do
      :ok = Exchange.subscribe("system.main.branch.push")

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("e2")}],
           body: [
             %{
               "type" => "PushEvent",
               "actor" => %{"login" => "bob"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "ref" => "refs/heads/main",
                 "head" => "def-#{System.unique_integer([:positive])}",
                 "commits" => []
               }
             }
           ]
         }}
      end

      assert {:ok, %{count: 1}} = GithubFirehose.poll(request_fun: stub)
      assert_receive {:event, %{topic: "system.main.branch.push"}}, 500
    end

    test "PullRequestEvent action=closed merged=true publishes pr.merged" do
      :ok = Exchange.subscribe("ticket.7.pr.merged")

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("e3")}],
           body: [
             %{
               "type" => "PullRequestEvent",
               "actor" => %{"login" => "carol"},
               "payload" => %{
                 "action" => "closed",
                 "pull_request" => %{
                   "merged" => true,
                   "head" => %{"ref" => "aiur/7"}
                 }
               }
             }
           ]
         }}
      end

      assert {:ok, %{count: 1}} = GithubFirehose.poll(request_fun: stub)
      assert_receive {:event, %{topic: "ticket.7.pr.merged"}}, 500
    end

    test "IssueCommentEvent publishes ticket.<id>.issue.commented" do
      :ok = Exchange.subscribe("ticket.42.issue.commented")

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("e4")}],
           body: [
             %{
               "type" => "IssueCommentEvent",
               "actor" => %{"login" => "dan"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "issue" => %{"number" => 42},
                 "comment" => %{"id" => 555, "body" => "looks good"}
               }
             }
           ]
         }}
      end

      assert {:ok, %{count: 1}} = GithubFirehose.poll(request_fun: stub)
      assert_receive {:event, %{topic: "ticket.42.issue.commented"}}, 500
    end

    test "IssueCommentEvent on a PR re-keys to the ticket id via the head ref" do
      # A PR-conversation comment fires as an IssueCommentEvent keyed by
      # the PR's number (21), but the agent owns ticket 7. The firehose
      # resolves PR 21 -> aiur/7 -> ticket 7 so the topic matches.
      :ok = Exchange.subscribe("ticket.7.issue.commented")

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("e5")}],
           body: [
             %{
               "type" => "IssueCommentEvent",
               "actor" => %{"login" => "dan"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "issue" => %{"number" => 21, "pull_request" => %{"url" => "x"}},
                 "comment" => %{"id" => 777, "body" => "ping"}
               }
             }
           ]
         }}
      end

      pr_lookup = fn 21 -> {:ok, "aiur/7"} end

      assert {:ok, %{count: 1}} =
               GithubFirehose.poll(request_fun: stub, pr_lookup_fun: pr_lookup)

      assert_receive {:event, %{topic: "ticket.7.issue.commented"}}, 500
    end

    test "IssueCommentEvent on a PR falls back to the raw number when resolution fails" do
      # Lookup error (network/rate-limit) or a non-aiur head ref must not
      # drop the event — degrade to the pre-resolution behavior.
      :ok = Exchange.subscribe("ticket.21.issue.commented")

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("e6")}],
           body: [
             %{
               "type" => "IssueCommentEvent",
               "actor" => %{"login" => "dan"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "issue" => %{"number" => 21, "pull_request" => %{"url" => "x"}},
                 "comment" => %{"id" => 778, "body" => "ping"}
               }
             }
           ]
         }}
      end

      pr_lookup = fn 21 -> {:error, :boom} end

      assert {:ok, %{count: 1}} =
               GithubFirehose.poll(request_fun: stub, pr_lookup_fun: pr_lookup)

      assert_receive {:event, %{topic: "ticket.21.issue.commented"}}, 500
    end

    test "IssueCommentEvent on a PR falls back to the raw number for a non-aiur head ref" do
      # Resolution succeeds but the head ref is not a canonical aiur/<id>
      # branch (e.g. a fork or renamed branch) — ref_to_topic rejects it,
      # so the with/else falls through to the raw number.
      :ok = Exchange.subscribe("ticket.21.issue.commented")

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("e7")}],
           body: [
             %{
               "type" => "IssueCommentEvent",
               "actor" => %{"login" => "dan"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "issue" => %{"number" => 21, "pull_request" => %{"url" => "x"}},
                 "comment" => %{"id" => 779, "body" => "ping"}
               }
             }
           ]
         }}
      end

      pr_lookup = fn 21 -> {:ok, "feature/not-aiur"} end

      assert {:ok, %{count: 1}} =
               GithubFirehose.poll(request_fun: stub, pr_lookup_fun: pr_lookup)

      assert_receive {:event, %{topic: "ticket.21.issue.commented"}}, 500
    end

    test "issue.commented passes the real tracked filter for an untracked/deactivated ticket" do
      # A :deactivated ticket is excluded from the orchestrator's tracked
      # set, so a naive publish would be :filtered. The bypass_contamination
      # opt lets the reactivation comment through. Use a restrictive
      # tracked_fn that rejects ticket 7 to prove the bypass fires.
      Publisher.set_tracked_fn(fn n -> to_string(n) != "7" end)
      :ok = Exchange.subscribe("ticket.7.issue.commented")

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("e8")}],
           body: [
             %{
               "type" => "IssueCommentEvent",
               "actor" => %{"login" => "dan"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "issue" => %{"number" => 21, "pull_request" => %{"url" => "x"}},
                 "comment" => %{"id" => 780, "body" => "ping"}
               }
             }
           ]
         }}
      end

      pr_lookup = fn 21 -> {:ok, "aiur/7"} end

      assert {:ok, %{count: 1}} =
               GithubFirehose.poll(request_fun: stub, pr_lookup_fun: pr_lookup)

      assert_receive {:event, %{topic: "ticket.7.issue.commented"}}, 500
    end

    test "PullRequestReviewCommentEvent re-keys to the ticket id via the PR head ref" do
      # Regression for #485: PR #49 can belong to ticket #35. The agent
      # subscribes to ticket.35.pr.review_comment, so publishing under
      # ticket.49 would silently miss the comment.
      :ok = Exchange.subscribe("ticket.35.pr.review_comment")

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("e9")}],
           body: [
             %{
               "type" => "PullRequestReviewCommentEvent",
               "actor" => %{"login" => "reviewer"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "pull_request" => %{
                   "number" => 49,
                   "head" => %{"ref" => "aiur/35"}
                 },
                 "comment" => %{"id" => 4_783_049_689, "body" => "Codex review result"}
               }
             }
           ]
         }}
      end

      assert {:ok, %{count: 1}} = GithubFirehose.poll(request_fun: stub)

      assert_receive {:event,
                      %{
                        topic: "ticket.35.pr.review_comment",
                        issue_number: "35",
                        comment: %{"id" => 4_783_049_689}
                      }},
                     500
    end

    test "PullRequestReviewCommentEvent falls back to the PR number when head resolution fails" do
      :ok = Exchange.subscribe("ticket.49.pr.review_comment")

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("e10")}],
           body: [
             %{
               "type" => "PullRequestReviewCommentEvent",
               "actor" => %{"login" => "reviewer"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "pull_request" => %{"number" => 49, "head" => %{"ref" => "feature/not-aiur"}},
                 "comment" => %{"id" => 123, "body" => "fallback"}
               }
             }
           ]
         }}
      end

      assert {:ok, %{count: 1}} = GithubFirehose.poll(request_fun: stub)
      assert_receive {:event, %{topic: "ticket.49.pr.review_comment"}}, 500
    end

    test "pr.review_comment bypasses the tracked filter for an untracked/deactivated ticket" do
      Publisher.set_tracked_fn(fn n -> to_string(n) != "35" end)
      :ok = Exchange.subscribe("ticket.35.pr.review_comment")

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("e11")}],
           body: [
             %{
               "type" => "PullRequestReviewCommentEvent",
               "actor" => %{"login" => "reviewer"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "pull_request" => %{"number" => 49, "head" => %{"ref" => "aiur/35"}},
                 "comment" => %{"id" => 124, "body" => "reactivate"}
               }
             }
           ]
         }}
      end

      assert {:ok, %{count: 1}} = GithubFirehose.poll(request_fun: stub)
      assert_receive {:event, %{topic: "ticket.35.pr.review_comment"}}, 500
    end

    # Regression: the Events API returns the same historical event on
    # every poll within its ~24h window. Without dedup, a single
    # `pr.opened` becomes one `📤 opened a PR` row per poll cycle.
    test "PullRequestEvent action=opened is deduped across polls by (repo, pr_number, head_sha)" do
      :ok = Exchange.subscribe("ticket.55.pr.opened")

      event = %{
        "type" => "PullRequestEvent",
        "actor" => %{"login" => "eve"},
        "repo" => %{"name" => "owner/repo"},
        "payload" => %{
          "action" => "opened",
          "pull_request" => %{
            "number" => 901,
            "head" => %{"ref" => "aiur/55", "sha" => "deadbeef"}
          }
        }
      }

      stub = fn _ -> {:ok, %{status: 200, headers: [{"ETag", ~s("e5")}], body: [event]}} end

      assert {:ok, %{count: 1}} = GithubFirehose.poll(request_fun: stub)
      assert_receive {:event, %{topic: "ticket.55.pr.opened"}}, 500

      # Subsequent poll returns the same event (e.g. ETag missed, restart).
      # Publisher should drop it via the dedup window.
      assert {:ok, %{count: 0}} = GithubFirehose.poll(request_fun: stub)
      refute_receive {:event, %{topic: "ticket.55.pr.opened"}}, 200
    end

    test "IssueCommentEvent is deduped across polls by (repo, issue_number, comment_id)" do
      :ok = Exchange.subscribe("ticket.66.issue.commented")

      event = %{
        "type" => "IssueCommentEvent",
        "actor" => %{"login" => "frank"},
        "repo" => %{"name" => "owner/repo"},
        "payload" => %{
          "issue" => %{"number" => 66},
          "comment" => %{"id" => 777, "body" => "ping"}
        }
      }

      stub = fn _ -> {:ok, %{status: 200, headers: [{"ETag", ~s("e6")}], body: [event]}} end

      assert {:ok, %{count: 1}} = GithubFirehose.poll(request_fun: stub)
      assert_receive {:event, %{topic: "ticket.66.issue.commented"}}, 500

      assert {:ok, %{count: 0}} = GithubFirehose.poll(request_fun: stub)
      refute_receive {:event, %{topic: "ticket.66.issue.commented"}}, 200
    end

    test "drops events for untracked tickets when tracked_fn rejects" do
      :ok = Exchange.subscribe("ticket.99.#")
      Publisher.set_tracked_fn(fn n -> n != "99" end)

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("e5")}],
           body: [
             %{
               "type" => "PushEvent",
               "actor" => %{"login" => "alice"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "ref" => "refs/heads/aiur/99",
                 "head" => "xyz-#{System.unique_integer([:positive])}",
                 "commits" => []
               }
             }
           ]
         }}
      end

      assert {:ok, %{count: 0}} = GithubFirehose.poll(request_fun: stub)
      refute_receive {:event, _}, 100
    end

    test "drops bot self-loop pushes" do
      :ok = Exchange.subscribe("ticket.7.branch.push")

      # Set bot_account so the Publisher's bot_self_loop filter applies
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_bot_account: "aiur-bot"
      )

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("e6")}],
           body: [
             %{
               "type" => "PushEvent",
               "actor" => %{"login" => "aiur-bot"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "ref" => "refs/heads/aiur/7",
                 "head" => "selfloop-#{System.unique_integer([:positive])}",
                 "commits" => []
               }
             }
           ]
         }}
      end

      assert {:ok, %{count: 0}} = GithubFirehose.poll(request_fun: stub)
      refute_receive {:event, _}, 100
    end

    test "transport error returns {:error, reason} and preserves caller etag" do
      stub = fn _ -> {:error, :timeout} end

      assert {:error, {:github_api_request, :timeout}} =
               GithubFirehose.poll(etag: ~s("e7"), request_fun: stub)
    end
  end
end

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

    test "merged PR events bypass the tracked filter for human-review tickets" do
      Publisher.set_tracked_fn(fn n -> to_string(n) != "7" end)
      :ok = Exchange.subscribe("ticket.7.pr.merged")

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("e3-merged-bypass")}],
           body: [
             %{
               "type" => "PullRequestEvent",
               "actor" => %{"login" => "carol"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "action" => "closed",
                 "pull_request" => %{
                   "number" => 559,
                   "merged" => true,
                   "head" => %{"ref" => "aiur/7", "sha" => "merge-bypass-sha"}
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
      assert_receive {:event, %{topic: "ticket.42.issue.commented", message: "looks good"}}, 500
    end

    test "IssueCommentEvent skips Agent Workpad comments" do
      :ok = Exchange.subscribe("ticket.42.issue.commented")

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("e4-workpad")}],
           body: [
             %{
               "id" => "workpad-comment",
               "type" => "IssueCommentEvent",
               "actor" => %{"login" => "dan"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "issue" => %{"number" => 42},
                 "comment" => %{"id" => 556, "body" => "## Agent Workpad\n\n- [x] done"}
               }
             }
           ]
         }}
      end

      assert {:ok, %{count: 0, last_event_id: "workpad-comment"}} =
               GithubFirehose.poll(request_fun: stub)

      refute_receive {:event, %{topic: "ticket.42.issue.commented"}}, 200
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

      assert_receive {:event, %{topic: "ticket.7.issue.commented", message: "ping"}}, 500
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
                        message: "Codex review result",
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

    test "IssueCommentEvent on a PR resolves the head ref once across deduped replays" do
      # The GitHub Events API replays in-window events for ~24h. Resolving a
      # PR-conversation comment to its ticket id costs a synchronous head-ref
      # GET; it must run on the first sighting only, not on every poll cycle
      # until the comment ages out of the dedup window. Checking the comment
      # dedup key before the lookup short-circuits the replays. (#408)
      :ok = Exchange.subscribe("ticket.7.issue.commented")

      # Distinct PR/comment ids from the other PR-comment tests so the
      # shared Publisher dedup table isn't pre-seeded for this key.
      event = pr_issue_comment_event("c1", 4080, 4081, "ping")
      stub = fn _ -> {:ok, %{status: 200, headers: [{"ETag", ~s("e5")}], body: [event]}} end

      parent = self()

      pr_lookup = fn 4080 ->
        send(parent, :head_ref_lookup)
        {:ok, "aiur/7"}
      end

      assert {:ok, %{count: 1}} =
               GithubFirehose.poll(request_fun: stub, pr_lookup_fun: pr_lookup)

      assert_receive {:event, %{topic: "ticket.7.issue.commented"}}, 500
      assert_receive :head_ref_lookup, 500

      # Replay: Publisher would dedup the publish anyway, but the head-ref
      # lookup must be short-circuited BEFORE it runs.
      assert {:ok, %{count: 0}} =
               GithubFirehose.poll(request_fun: stub, pr_lookup_fun: pr_lookup)

      refute_receive {:event, %{topic: "ticket.7.issue.commented"}}, 200
      refute_receive :head_ref_lookup, 200
    end

    test "does not backfill when the previous event watermark is still on page 1" do
      :ok = Exchange.subscribe("ticket.66.issue.commented")

      page_1 =
        [
          issue_comment_event("new-1", 66, 778, "fresh ping"),
          ignored_event("last-seen")
        ] ++ ignored_events("page-1-filler", 28)

      parent = self()

      stub = fn req ->
        page = request_page(req)
        send(parent, {:events_page_requested, page})

        assert page == "1"
        {:ok, %{status: 200, headers: [{"ETag", ~s("e7")}], body: page_1}}
      end

      assert {:ok, %{count: 1, last_event_id: "new-1"}} =
               GithubFirehose.poll(request_fun: stub, last_event_id: "last-seen")

      assert_receive {:event, %{topic: "ticket.66.issue.commented"}}, 500
      assert_receive {:events_page_requested, "1"}
      refute_receive {:events_page_requested, "2"}, 100
    end

    test "backfills saturated pages until a PR issue comment before the watermark is delivered" do
      :ok = Exchange.subscribe("ticket.37.issue.commented")

      page_1 = ignored_events("burst", 30)

      page_2 = [
        pr_issue_comment_event("page-2-comment", 52, 4_784_938_941, "please revisit"),
        ignored_event("last-seen"),
        issue_comment_event("older-than-watermark", 37, 999, "too old")
      ]

      parent = self()

      stub = fn req ->
        page = request_page(req)
        send(parent, {:events_page_requested, page})

        body =
          case page do
            "1" -> page_1
            "2" -> page_2
          end

        {:ok, %{status: 200, headers: [{"ETag", ~s("e8")}], body: body}}
      end

      pr_lookup = fn 52 -> {:ok, "aiur/37"} end

      assert {:ok, %{count: 1, last_event_id: "burst-1"}} =
               GithubFirehose.poll(
                 request_fun: stub,
                 pr_lookup_fun: pr_lookup,
                 last_event_id: "last-seen"
               )

      assert_receive {:event,
                      %{
                        topic: "ticket.37.issue.commented",
                        comment: %{"id" => 4_784_938_941, "body" => "please revisit"}
                      }},
                     500

      refute_receive {:event, %{comment: %{"id" => 999}}}, 100
      assert_receive {:events_page_requested, "1"}
      assert_receive {:events_page_requested, "2"}
    end

    test "backfill fetch errors fail the poll without advancing the watermark" do
      :ok = Exchange.subscribe("ticket.66.issue.commented")

      page_1 = [issue_comment_event("new-1", 66, 778, "fresh ping") | ignored_events("burst", 29)]

      stub = fn req ->
        case request_page(req) do
          "1" -> {:ok, %{status: 200, headers: [{"ETag", ~s("e9")}], body: page_1}}
          "2" -> {:error, :timeout}
        end
      end

      assert {:error, {:github, :timeout, %{reason: :timeout}}} =
               GithubFirehose.poll(request_fun: stub, last_event_id: "last-seen")

      refute_receive {:event, %{topic: "ticket.66.issue.commented"}}, 100
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

    test "transport error returns the classified taxonomy error and preserves caller etag" do
      stub = fn _ -> {:error, :timeout} end

      assert {:error, {:github, :timeout, %{reason: :timeout}}} =
               GithubFirehose.poll(etag: ~s("e7"), request_fun: stub)
    end
  end

  defp request_page(%{url: url}) do
    url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("page")
  end

  defp ignored_events(prefix, count) do
    Enum.map(1..count, &ignored_event("#{prefix}-#{&1}"))
  end

  defp ignored_event(id) do
    %{
      "id" => id,
      "type" => "IssuesEvent",
      "actor" => %{"login" => "noise"},
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{}
    }
  end

  defp issue_comment_event(id, issue_number, comment_id, body) do
    %{
      "id" => id,
      "type" => "IssueCommentEvent",
      "actor" => %{"login" => "reviewer"},
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{
        "issue" => %{"number" => issue_number},
        "comment" => %{"id" => comment_id, "body" => body}
      }
    }
  end

  defp pr_issue_comment_event(id, pr_number, comment_id, body) do
    put_in(
      issue_comment_event(id, pr_number, comment_id, body),
      [
        "payload",
        "issue",
        "pull_request"
      ],
      %{"url" => "x"}
    )
  end
end

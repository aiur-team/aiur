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

    # Not 42: other tests' ticket.42 comments get late orchestrator alerts (#3598).
    {:ok, ticket: Integer.to_string(System.unique_integer([:positive]))}
  end

  describe "poll/1" do
    test "PushEvent on ticket branch is ignored", %{ticket: ticket} do
      :ok = Exchange.subscribe("ticket.#{ticket}.branch.push")

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
                 "ref" => "refs/heads/aiur/#{ticket}",
                 "head" => "abc-#{System.unique_integer([:positive])}",
                 "commits" => [%{"message" => "wip"}]
               }
             }
           ]
         }}
      end

      assert {:ok, %{etag: ~s("e1"), count: 0}} = GithubFirehose.poll(request_fun: stub)
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

    test "sparse PullRequestEvent action=merged publishes pr.merged" do
      :ok = Exchange.subscribe("ticket.7.pr.merged")

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("e3")}],
           body: [
             %{
               "type" => "PullRequestEvent",
               "created_at" => "2026-07-12T17:59:00Z",
               "actor" => %{"login" => "carol"},
               "payload" => %{
                 "action" => "merged",
                 "pull_request" => %{
                   "number" => 7,
                   "head" => %{"ref" => "aiur/7"}
                 }
               }
             }
           ]
         }}
      end

      assert {:ok, %{count: 1}} =
               GithubFirehose.poll(
                 request_fun: stub,
                 boot_time: ~U[2026-07-12 18:00:00Z] |> DateTime.to_unix()
               )

      assert_receive {:event, %{topic: "ticket.7.pr.merged"}}, 500
    end

    test "PullRequestEvent ready_for_review publishes its own topic" do
      :ok = Exchange.subscribe("ticket.7.pr.#")

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("ready")}],
           body: [
             %{
               "id" => "opened-event",
               "type" => "PullRequestEvent",
               "actor" => %{"login" => "carol"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "action" => "opened",
                 "pull_request" => %{
                   "number" => 7,
                   "draft" => true,
                   "head" => %{"ref" => "aiur/7-readable", "sha" => String.duplicate("a", 40)}
                 }
               }
             },
             %{
               "id" => "ready-event",
               "type" => "PullRequestEvent",
               "actor" => %{"login" => "carol"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "action" => "ready_for_review",
                 "pull_request" => %{
                   "number" => 7,
                   "draft" => false,
                   "head" => %{"ref" => "aiur/7-readable", "sha" => String.duplicate("a", 40)}
                 }
               }
             }
           ]
         }}
      end

      assert {:ok, %{count: 2}} = GithubFirehose.poll(request_fun: stub)
      assert_receive {:event, %{topic: "ticket.7.pr.opened"}}, 500
      assert_receive {:event, %{topic: "ticket.7.pr.ready_for_review"}}, 500
      assert {:ok, %{count: 0}} = GithubFirehose.poll(request_fun: stub)
      refute_receive {:event, %{topic: "ticket.7.pr.opened"}}, 100
      refute_receive {:event, %{topic: "ticket.7.pr.ready_for_review"}}, 100
    end

    test "PullRequestEvent converted_to_draft remains ignored" do
      :ok = Exchange.subscribe("ticket.7.#")

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("draft")}],
           body: [
             %{
               "id" => "draft-event",
               "type" => "PullRequestEvent",
               "actor" => %{"login" => "carol"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "action" => "converted_to_draft",
                 "pull_request" => %{
                   "number" => 7,
                   "draft" => true,
                   "head" => %{"ref" => "aiur/7-readable", "sha" => String.duplicate("b", 40)}
                 }
               }
             }
           ]
         }}
      end

      assert {:ok, %{count: 0}} = GithubFirehose.poll(request_fun: stub)

      # Scoped to `ticket.7.pr.` rather than all of `ticket.7.`, which is the
      # subscription. A `PullRequestEvent` can only ever become `ticket.<id>.pr.*`
      # (`github_firehose.ex` `pr_topic/3`), so this is the full strength of the
      # claim — while refuting the whole namespace also asserted that no *other*
      # part of Aiur emits anything about ticket 7 for the duration, which is not
      # this test's business and is not true: the exchange is global, and
      # `orchestrator/comment_wake_test.exs` publishes
      # `ticket.7.merge.unauthorized_merger` from an async case whose work can
      # still be in flight when this one subscribes.
      refute_receive {:event, %{topic: "ticket.7.pr." <> _}}, 100
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
                 "action" => "merged",
                 "pull_request" => %{
                   "number" => 559,
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

    test "IssueCommentEvent is ignored", %{ticket: ticket} do
      :ok = Exchange.subscribe("ticket.#{ticket}.issue.commented")

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
                 "issue" => %{"number" => String.to_integer(ticket)},
                 "comment" => %{"id" => 555, "body" => "looks good"}
               }
             }
           ]
         }}
      end

      assert {:ok, %{count: 0}} = GithubFirehose.poll(request_fun: stub)
      refute_receive {:event, _}, 100
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

    test "drops events for untracked tickets when tracked_fn rejects", %{ticket: ticket} do
      :ok = Exchange.subscribe("ticket.#{ticket}.#")
      Publisher.set_tracked_fn(fn n -> n != ticket end)

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("e5")}],
           body: [
             %{
               "type" => "PullRequestEvent",
               "actor" => %{"login" => "alice"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "action" => "opened",
                 "pull_request" => %{
                   "number" => 990,
                   "head" => %{"ref" => "aiur/#{ticket}", "sha" => "xyz-#{System.unique_integer([:positive])}"}
                 }
               }
             }
           ]
         }}
      end

      assert {:ok, %{count: 0}} = GithubFirehose.poll(request_fun: stub)
      refute_receive {:event, _}, 100
    end

    test "drops bot self-loop PR events" do
      :ok = Exchange.subscribe("ticket.7.pr.opened")

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
               "type" => "PullRequestEvent",
               "actor" => %{"login" => "aiur-bot"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "action" => "opened",
                 "pull_request" => %{
                   "number" => 770,
                   "head" => %{"ref" => "aiur/7", "sha" => "selfloop-#{System.unique_integer([:positive])}"}
                 }
               }
             }
           ]
         }}
      end

      assert {:ok, %{count: 0}} = GithubFirehose.poll(request_fun: stub)
      refute_receive {:event, _}, 100
    end

    test "publishes authoritative merge events performed by the bot account" do
      :ok = Exchange.subscribe("ticket.7.pr.merged")

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
           headers: [{"ETag", ~s("merge-by-bot")}],
           body: [
             %{
               "type" => "PullRequestEvent",
               "actor" => %{"login" => "aiur-bot"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "action" => "closed",
                 "pull_request" => %{
                   "number" => 771,
                   "merged" => true,
                   "merged_by" => %{"login" => "aiur-bot"},
                   "head" => %{"ref" => "aiur/7", "sha" => "bot-merge-head"}
                 }
               }
             }
           ]
         }}
      end

      assert {:ok, %{count: 1}} = GithubFirehose.poll(request_fun: stub)

      assert_receive {:event,
                      %{
                        topic: "ticket.7.pr.merged",
                        pr: %{"merged_by" => %{"login" => "aiur-bot"}}
                      }},
                     500
    end
  end
end

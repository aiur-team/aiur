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

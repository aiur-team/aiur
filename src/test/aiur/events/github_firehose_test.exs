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
    test "PushEvent on ticket branch is ignored" do
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

      assert {:ok, %{etag: ~s("e1"), count: 0}} = GithubFirehose.poll(request_fun: stub)
      refute_receive {:event, %{topic: "ticket.42.branch.push"}}, 100
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

    test "startup reconciliation persists a pre-boot non-ticket merge from a later bounded page" do
      page_1 = ignored_events("startup-burst", 30)

      page_2 = [
        pr_merged_event("historical-merge", "release/2026-07", 812, "historical-head", created_at: "2026-07-12T16:00:00Z")
      ]

      parent = self()

      stub = fn req ->
        page = request_page(req)
        send(parent, {:events_page_requested, page})
        body = if page == "1", do: page_1, else: page_2
        {:ok, %{status: 200, headers: [{"ETag", ~s("startup-etag")}], body: body}}
      end

      persist = fn merge ->
        send(parent, {:recent_merge_persisted, merge})
        {:ok, %{status: :accepted, merge: merge}}
      end

      boot_time = ~U[2026-07-12 18:00:00Z] |> DateTime.to_unix()

      assert {:ok, %{count: 0, pages_fetched: 2, partial_window?: false}} =
               GithubFirehose.poll(
                 request_fun: stub,
                 recent_merge_fun: persist,
                 boot_time: boot_time,
                 run_id: "current-run"
               )

      assert_receive {:recent_merge_persisted,
                      %Aiur.RecentMerge{
                        number: 812,
                        ticket_id: nil,
                        backfilled?: true,
                        live_observed?: false,
                        observed_run_id: nil
                      }},
                     500

      assert_receive {:events_page_requested, "1"}
      assert_receive {:events_page_requested, "2"}
    end

    test "a durable merge-store failure holds the poll cursor but preserves ticket merge publication" do
      :ok = Exchange.subscribe("ticket.77.pr.merged")

      event =
        pr_merged_event("live-merge", "aiur/77-reconcile-outcomes", 8_177, "live-head", created_at: "2026-07-12T18:00:00Z")

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("failed-persist-etag")}],
           body: [event, ignored_event("last-seen")]
         }}
      end

      persist = fn _merge -> {:error, {:append_failed, :disk_full}} end
      boot_time = ~U[2026-07-12 17:00:00Z] |> DateTime.to_unix()

      assert {:error, {:recent_merge_persistence, {:append_failed, :disk_full}, %{etag: ~s("failed-persist-etag"), last_event_id: "live-merge"}}} =
               GithubFirehose.poll(
                 request_fun: stub,
                 recent_merge_fun: persist,
                 last_event_id: "last-seen",
                 boot_time: boot_time,
                 run_id: "current-run"
               )

      assert_receive {:event, %{topic: "ticket.77.pr.merged", pr: %{"number" => 8_177}}}, 500
    end

    test "a saturated reconciliation cap is disclosed instead of fetching an unbounded window" do
      parent = self()

      stub = fn req ->
        page = request_page(req)
        send(parent, {:events_page_requested, String.to_integer(page)})
        {:ok, %{status: 200, headers: [{"ETag", ~s("saturated-etag")}], body: ignored_events("p#{page}", 30)}}
      end

      mark_reconciliation = fn partial?, pages ->
        send(parent, {:reconciliation_marked, partial?, pages})
        :ok
      end

      assert {:ok, %{pages_fetched: 5, partial_window?: true}} =
               GithubFirehose.poll(
                 request_fun: stub,
                 recent_merge_reconciliation_fun: mark_reconciliation
               )

      assert_receive {:reconciliation_marked, true, 5}
      assert Enum.map(1..5, fn _ -> receive do: ({:events_page_requested, page} -> page) end) == [1, 2, 3, 4, 5]
      refute_receive {:events_page_requested, 6}, 100
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

    test "IssueCommentEvent is ignored" do
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

      assert {:ok, %{count: 0}} = GithubFirehose.poll(request_fun: stub)
      refute_receive {:event, %{topic: "ticket.42.issue.commented"}}, 100
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

    test "does not backfill when the previous event watermark is still on page 1" do
      :ok = Exchange.subscribe("ticket.66.pr.opened")

      page_1 =
        [
          pr_opened_event("new-1", 66, 778, "head-sha-66"),
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

      assert_receive {:event, %{topic: "ticket.66.pr.opened"}}, 500
      assert_receive {:events_page_requested, "1"}
      refute_receive {:events_page_requested, "2"}, 100
    end

    test "backfills saturated pages until a PR state event before the watermark is delivered" do
      :ok = Exchange.subscribe("ticket.37.pr.opened")

      page_1 = ignored_events("burst", 30)

      page_2 = [
        pr_opened_event("page-2-pr", 37, 52, "page-2-head"),
        ignored_event("last-seen"),
        pr_opened_event("older-than-watermark", 38, 53, "older-head")
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

      assert {:ok, %{count: 1, last_event_id: "burst-1"}} =
               GithubFirehose.poll(
                 request_fun: stub,
                 last_event_id: "last-seen"
               )

      assert_receive {:event,
                      %{
                        topic: "ticket.37.pr.opened",
                        pr: %{"number" => 52}
                      }},
                     500

      refute_receive {:event, %{topic: "ticket.38.pr.opened"}}, 100
      assert_receive {:events_page_requested, "1"}
      assert_receive {:events_page_requested, "2"}
    end

    test "backfill fetch errors fail the poll without advancing the watermark" do
      :ok = Exchange.subscribe("ticket.66.pr.opened")

      page_1 = [pr_opened_event("new-1", 66, 778, "fresh-head") | ignored_events("burst", 29)]

      stub = fn req ->
        case request_page(req) do
          "1" -> {:ok, %{status: 200, headers: [{"ETag", ~s("e9")}], body: page_1}}
          "2" -> {:error, :timeout}
        end
      end

      assert {:error, {:github, :timeout, %{reason: :timeout}}} =
               GithubFirehose.poll(request_fun: stub, last_event_id: "last-seen")

      refute_receive {:event, %{topic: "ticket.66.pr.opened"}}, 100
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
               "type" => "PullRequestEvent",
               "actor" => %{"login" => "alice"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "action" => "opened",
                 "pull_request" => %{
                   "number" => 990,
                   "head" => %{"ref" => "aiur/99", "sha" => "xyz-#{System.unique_integer([:positive])}"}
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

  defp pr_opened_event(id, ticket_id, pr_number, head_sha) do
    %{
      "id" => id,
      "type" => "PullRequestEvent",
      "actor" => %{"login" => "reviewer"},
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{
        "action" => "opened",
        "pull_request" => %{
          "number" => pr_number,
          "head" => %{"ref" => "aiur/#{ticket_id}", "sha" => head_sha}
        }
      }
    }
  end

  defp pr_merged_event(id, head_ref, pr_number, head_sha, opts) do
    %{
      "id" => id,
      "type" => "PullRequestEvent",
      "created_at" => Keyword.fetch!(opts, :created_at),
      "actor" => %{"login" => "merger"},
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{
        "action" => "closed",
        "pull_request" => %{
          "number" => pr_number,
          "title" => "Merged PR #{pr_number}",
          "body" => "Bounded summary",
          "html_url" => "https://github.com/owner/repo/pull/#{pr_number}",
          "merged" => true,
          "merged_at" => Keyword.fetch!(opts, :created_at),
          "merge_commit_sha" => "merge-#{pr_number}",
          "head" => %{"ref" => head_ref, "sha" => head_sha},
          "merged_by" => %{"login" => "merger"}
        }
      }
    }
  end
end

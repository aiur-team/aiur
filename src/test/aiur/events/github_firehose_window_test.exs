defmodule Aiur.Events.GithubFirehoseWindowTest do
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
    test "304 returns previously-cached etag, no publishes" do
      :ok = Exchange.subscribe("ticket.*.pr.#")
      :ok = Exchange.subscribe("system.*.branch.push")
      stub = fn %{etag: ~s("e1")} -> {:ok, %{status: 304, headers: [{"ETag", ~s("e1")}], body: ""}} end

      assert {:ok, %{etag: ~s("e1"), count: 0}} =
               GithubFirehose.poll(etag: ~s("e1"), request_fun: stub)

      refute_receive {:event, _}, 100
    end

    # #2354: the cheapest tick is the 304 revalidation, and the per-tick window
    # metric must not zero it out. One actual HTTP read happened, so the window
    # metric reports page 1 of a complete (empty) window — not 0 pages, which
    # would under-count the poller's steady-state cost.
    test "304 reports one page fetched and a complete window" do
      stub = fn %{etag: ~s("e1")} ->
        {:ok, %{status: 304, headers: [{"ETag", ~s("e1")}], body: ""}}
      end

      assert {:ok, %{etag: ~s("e1"), count: 0, pages_fetched: 1, partial_window?: false}} =
               GithubFirehose.poll(etag: ~s("e1"), request_fun: stub)
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

      assert_receive {:events_page_requested, "1"}, 1000
      assert_receive {:events_page_requested, "2"}, 1000
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

    test "a saturated reconciliation window bound is disclosed instead of fetching an unbounded window" do
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

      assert {:ok, %{pages_fetched: 10, partial_window?: true}} =
               GithubFirehose.poll(
                 request_fun: stub,
                 recent_merge_reconciliation_fun: mark_reconciliation
               )

      assert_receive {:reconciliation_marked, true, 10}, 1000
      assert Enum.map(1..10, fn _ -> receive do: ({:events_page_requested, page} -> page) end) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
      refute_receive {:events_page_requested, 11}, 100
    end

    # Regression for #2354: on a stream active enough that the previous
    # watermark sits on page 6, the old `@max_event_pages 5` cap truncated the
    # window on every tick and silently dropped the newest events beyond page 5.
    # The backfill now pages until the watermark is found, so a six-page window
    # is read completely and an event on page 6 is published instead of lost.
    test "pages past the old 5-page cap until the previous watermark is found" do
      :ok = Exchange.subscribe("ticket.66.pr.opened")

      parent = self()

      pages = %{
        "1" => ignored_events("burst-1", 30),
        "2" => ignored_events("burst-2", 30),
        "3" => ignored_events("burst-3", 30),
        "4" => ignored_events("burst-4", 30),
        "5" => ignored_events("burst-5", 30),
        "6" => [
          pr_opened_event("page-6-pr", 66, 779, "page-6-head"),
          ignored_event("watermark"),
          ignored_event("older-than-watermark")
        ]
      }

      stub = fn req ->
        page = request_page(req)
        send(parent, {:events_page_requested, String.to_integer(page)})
        {:ok, %{status: 200, headers: [{"ETag", ~s("e2354")}], body: Map.fetch!(pages, page)}}
      end

      assert {:ok, %{pages_fetched: 6, partial_window?: false, count: 1, last_event_id: "burst-1-1"}} =
               GithubFirehose.poll(request_fun: stub, last_event_id: "watermark")

      assert_receive {:event, %{topic: "ticket.66.pr.opened", pr: %{"number" => 779}}}, 500

      assert Enum.map(1..6, fn _ -> receive do: ({:events_page_requested, page} -> page) end) == [1, 2, 3, 4, 5, 6]
      refute_receive {:events_page_requested, 7}, 100
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
      assert_receive {:events_page_requested, "1"}, 1000
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
      assert_receive {:events_page_requested, "1"}, 1000
      assert_receive {:events_page_requested, "2"}, 1000
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

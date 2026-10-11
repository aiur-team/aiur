defmodule Aiur.Orchestrator.Deactivate.WatchTargetTest do
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.CommentPolling

  import Aiur.OrchestratorDeactivateSupport

  describe "watch-target discovery (agent:watch PR comment polling)" do
    test "open agent:watch PR becomes a pr#-keyed target and publishes ticket.<pr#>.pr.review_comment" do
      parent = self()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        pr_watch_enabled: true
      )

      :ok = Exchange.subscribe("ticket.314.pr.review_comment")

      watch_pr = %{
        "number" => 314,
        "state" => "open",
        "head" => %{"ref" => "feature/human-branch"},
        "labels" => [%{"name" => "agent:watch"}]
      }

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/314/comments?") ->
            {:ok, %{status: 200, body: []}}

          # The PR object is passed through; the poller must NOT branch-derive.
          String.contains?(url, "/pulls?") ->
            send(parent, {:unexpected_pull_request_lookup, url})
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/graphql") ->
            review_threads_response([
              %{
                "id" => "PRRT_watch_314",
                "isResolved" => false,
                "path" => "lib/app.ex",
                "line" => 7,
                "comments" => %{
                  "nodes" => [
                    review_thread_comment(31_401, "its-everdred", "watched PR feedback")
                  ]
                }
              }
            ])
        end
      end

      state = %Orchestrator.State{
        running: %{},
        github_comments_since: "2026-06-25T00:00:00Z"
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging", "rework", "ci-wait"] -> {:ok, []} end,
          watch_pull_request_fetcher: fn "agent:watch" -> {:ok, [watch_pr]} end
        )

      assert next.github_comments_since == %{"314" => "2026-06-25T00:00:00Z"}

      receive_barrier(
        {:event,
         %{
           topic: "ticket.314.pr.review_comment",
           source: :github,
           message: "watched PR feedback"
         }}
      )

      # The synchronous poll return proves target resolution is complete.
      refute_received {:unexpected_pull_request_lookup, _url}
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "watch targets are isolated: one failing PR does not stall or rewind the others" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        pr_watch_enabled: true
      )

      healthy_pr = %{"number" => 100, "state" => "open", "head" => %{"ref" => "branch-a"}}
      flaky_pr = %{"number" => 200, "state" => "open", "head" => %{"ref" => "branch-b"}}

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/100/comments?") ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "id" => 10_001,
                   "body" => "healthy watch comment",
                   "updated_at" => "2026-06-25T01:00:00Z",
                   "user" => %{"login" => "its-everdred"}
                 }
               ]
             }}

          # The flaky PR's issue/conversation fetch errors, so its cursor must
          # not advance — but it must not block the healthy PR either.
          String.contains?(url, "/issues/200/comments?") ->
            {:ok, %{status: 500, body: %{"message" => "boom"}}}

          String.contains?(url, "/graphql") ->
            empty_review_threads_response()
        end
      end

      state = %Orchestrator.State{
        running: %{},
        github_comments_since: %{
          "100" => "2026-06-25T00:00:00Z",
          "200" => "2026-06-25T00:00:00Z"
        }
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          max_concurrency: 1,
          review_issue_fetcher: fn ["human-review", "merging", "rework", "ci-wait"] -> {:ok, []} end,
          watch_pull_request_fetcher: fn "agent:watch" -> {:ok, [healthy_pr, flaky_pr]} end
        )

      # Healthy target advanced (−1s rewind); flaky target held its cursor.
      assert next.github_comments_since == %{
               "100" => "2026-06-25T00:59:59Z",
               "200" => "2026-06-25T00:00:00Z"
             }
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "closed/merged watch PRs are excluded and the target set is capped (drop logged)" do
      parent = self()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        pr_watch_enabled: true
      )

      open_prs =
        for n <- 1..3 do
          %{"number" => n, "state" => "open", "head" => %{"ref" => "branch-#{n}"}}
        end

      merged_pr = %{
        "number" => 900,
        "state" => "closed",
        "merged_at" => "2026-06-25T00:00:00Z",
        "head" => %{"ref" => "merged-branch"}
      }

      closed_pr = %{"number" => 901, "state" => "closed", "head" => %{"ref" => "closed-branch"}}

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/") and String.contains?(url, "/comments?") ->
            [_, id] = Regex.run(~r{/issues/([^/]+)/comments\?}, url)
            send(parent, {:issue_comments_requested, id})
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/graphql") ->
            empty_review_threads_response()
        end
      end

      state = %Orchestrator.State{running: %{}, github_comments_since: %{}}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          CommentPolling.poll_github_comments(state,
            repo: "owner/repo",
            request_fun: request_fun,
            max_concurrency: 1,
            watch_comment_target_limit: 2,
            review_issue_fetcher: fn ["human-review", "merging", "rework", "ci-wait"] -> {:ok, []} end,
            watch_pull_request_fetcher: fn "agent:watch" ->
              {:ok, open_prs ++ [merged_pr, closed_pr]}
            end
          )
        end)

      # Merged/closed PRs never become targets, and the open set is capped at 2.
      # A watched PR's target IS its PR number, so the poller hits
      # /issues/<pr#>/comments for both the issue and PR-conversation passes —
      # dedup to the distinct PR numbers actually polled.
      polled = drain_issue_comment_requests([]) |> Enum.uniq()

      assert length(polled) == 2
      assert Enum.all?(polled, &(&1 in ["1", "2", "3"]))
      refute "900" in polled
      refute "901" in polled
      assert log =~ "watch_comment_poll_targets capped"
      assert log =~ "dropped=1"
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "no watch targets are produced when pr_watch is disabled (default)" do
      parent = self()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      request_fun = fn %{url: url} ->
        send(parent, {:unexpected_request, url})
        {:ok, %{status: 200, body: []}}
      end

      state = %Orchestrator.State{running: %{}, github_comments_since: %{}}

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging", "rework", "ci-wait"] -> {:ok, []} end,
          watch_pull_request_fetcher: fn _label ->
            send(parent, :unexpected_watch_fetch)
            {:ok, []}
          end
        )

      # No targets at all (no running, no human-review, watch disabled) ->
      # the poller is never invoked. Only the per-cycle conditional issue-list
      # cache may differ; every other field, `approved_heads` included, must be
      # untouched.
      assert put_in(next.ci_lifecycle.poll_cache[:issue_list_cache], nil) ==
               put_in(state.ci_lifecycle.poll_cache[:issue_list_cache], nil)

      # poll_github_comments/2 returns after its feature gate, so neither
      # callback can run later for this invocation.
      refute_received :unexpected_watch_fetch
      refute_received {:unexpected_request, _url}
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end
  end
end

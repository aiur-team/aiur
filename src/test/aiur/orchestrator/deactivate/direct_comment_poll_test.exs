defmodule Aiur.Orchestrator.Deactivate.DirectCommentPollTest do
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.CommentPolling

  import Aiur.OrchestratorDeactivateSupport

  describe "issue.commented firehose reactivation (subscriber wiring)" do
    test "direct comment poll watches human-review issues without running entries" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      issue = %Issue{id: "57", identifier: "57", state: "human-review"}
      :ok = Exchange.subscribe("ticket.57.pr.review_comment")

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/57/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls?") ->
            {:ok,
             %{
               status: 200,
               body: [%{"number" => 61, "head" => %{"ref" => "aiur/57", "repo" => %{"full_name" => "owner/repo"}}}]
             }}

          String.contains?(url, "/issues/61/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls/61/reviews") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/graphql") ->
            review_threads_response([
              %{
                "id" => "PRRT_human_review_only",
                "isResolved" => false,
                "path" => "lib/app.ex",
                "line" => 12,
                "comments" => %{
                  "nodes" => [
                    review_thread_comment(5701, "its-everdred", "same-whale transfers should stay sequential")
                  ]
                }
              }
            ])
        end
      end

      state = %Orchestrator.State{
        running: %{},
        github_comments_since: "2026-06-24T11:00:00Z"
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging", "rework", "ci-wait"] -> {:ok, [issue]} end
        )

      assert next.github_comments_since == %{"57" => "2026-06-24T11:00:00Z"}

      receive_barrier(
        {:event,
         %{
           topic: "ticket.57.pr.review_comment",
           source: :github,
           message: "same-whale transfers should stay sequential"
         }}
      )
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "direct comment poll watches merging issues without running entries (#696)" do
      # The comment listener must cover merging tickets too, not only
      # human-review, so a reviewer's last-minute comment during merge is seen
      # and can promote the ticket to rework — independent of `active_states`.
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      issue = %Issue{id: "63", identifier: "63", state: "merging"}
      :ok = Exchange.subscribe("ticket.63.issue.commented")

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/63/comments?") ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "id" => 6301,
                   "body" => "hold the merge — please revert the rename",
                   "updated_at" => "2026-06-24T12:00:00Z",
                   "user" => %{"login" => "its-everdred"}
                 }
               ]
             }}

          String.contains?(url, "/pulls?") ->
            {:ok, %{status: 200, body: []}}
        end
      end

      state = %Orchestrator.State{
        running: %{},
        github_comments_since: "2026-06-24T11:00:00Z"
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging", "rework", "ci-wait"] -> {:ok, [issue]} end
        )

      assert next.github_comments_since == %{"63" => "2026-06-24T11:59:59Z"}

      receive_barrier(
        {:event,
         %{
           topic: "ticket.63.issue.commented",
           source: :github,
           message: "hold the merge — please revert the rename"
         }}
      )
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "direct comment poll keeps running and human-review targets" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      human_review_issue = %Issue{id: "57", identifier: "57", state: "human-review"}
      :ok = Exchange.subscribe("ticket.42.issue.commented")
      :ok = Exchange.subscribe("ticket.57.pr.review_comment")

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/42/comments?") ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "id" => 4201,
                   "body" => "running target comment",
                   "updated_at" => "2026-06-24T12:00:00Z",
                   "user" => %{"login" => "its-everdred"}
                 }
               ]
             }}

          String.contains?(url, "/issues/57/comments?") ->
            {:ok, %{status: 200, body: []}}

          # Every target now reads the same open-pull-request listing URL, so the
          # stub can no longer tell the lookups apart by URL. It returns the one
          # open pull request and lets `TicketBranch.ticket_branch?/2` do the
          # filtering: ticket 57 matches `aiur/57`, ticket 42 matches nothing.
          String.contains?(url, "/pulls?") ->
            {:ok,
             %{
               status: 200,
               body: [%{"number" => 61, "head" => %{"ref" => "aiur/57", "repo" => %{"full_name" => "owner/repo"}}}]
             }}

          String.contains?(url, "/issues/61/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls/61/reviews") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/graphql") ->
            review_threads_response([
              %{
                "id" => "PRRT_human_review_with_running",
                "isResolved" => false,
                "path" => "lib/app.ex",
                "line" => 12,
                "comments" => %{
                  "nodes" => [
                    review_thread_comment(5702, "its-everdred", "human-review target comment")
                  ]
                }
              }
            ])
        end
      end

      state = %Orchestrator.State{
        running: %{
          "issue-42" => %{
            identifier: "42",
            issue: %Issue{id: "issue-42", state: "in-progress", identifier: "42"},
            control: %{status: :working}
          }
        },
        github_comments_since: "2026-06-24T11:00:00Z"
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging", "rework", "ci-wait"] -> {:ok, [human_review_issue]} end
        )

      assert next.github_comments_since == %{
               "42" => "2026-06-24T11:59:59Z",
               "57" => "2026-06-24T11:00:00Z"
             }

      receive_barrier({:event, %{topic: "ticket.42.issue.commented", message: "running target comment"}})

      receive_barrier({:event, %{topic: "ticket.57.pr.review_comment", message: "human-review target comment"}})
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "direct comment poll bounds human-review targets by oldest cursor" do
      parent = self()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      issues =
        for id <- ~w(10 11 12 13) do
          %Issue{
            id: id,
            identifier: id,
            state: "human-review",
            updated_at: datetime!("2026-06-24T12:00:00Z")
          }
        end

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/") and String.contains?(url, "/comments?") ->
            [_, id] = Regex.run(~r{/issues/([^/]+)/comments\?}, url)
            send(parent, {:issue_comments_requested, id})
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls?") ->
            send(parent, {:pulls_requested, url})
            {:ok, %{status: 200, body: []}}
        end
      end

      state = %Orchestrator.State{
        running: %{},
        github_comments_since: %{
          "10" => "2026-06-24T12:00:00Z",
          "11" => "2026-06-24T10:00:00Z",
          "12" => "2026-06-24T11:00:00Z",
          "13" => "2026-06-24T09:00:00Z"
        }
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging", "rework", "ci-wait"] -> {:ok, issues} end,
          human_review_comment_target_limit: 2,
          max_concurrency: 1
        )

      receive_barrier({:issue_comments_requested, "13"})
      receive_barrier({:issue_comments_requested, "11"})
      # poll_github_comments/2 synchronously completes the bounded target scan.
      refute_received {:issue_comments_requested, _}
      # One pull-request lookup per bounded target, and one request each: the
      # `head=<owner>:aiur/<n>` probe that used to precede the listing is gone,
      # so each target issues only the open-pull-request listing read.
      receive_barrier({:pulls_requested, pulls_13})
      receive_barrier({:pulls_requested, pulls_11})
      refute_received {:pulls_requested, _}

      for url <- [pulls_13, pulls_11] do
        refute String.contains?(url, "head=")
        assert String.contains?(url, "state=open")
        assert String.contains?(url, "per_page=100")
      end

      assert next.github_comments_since == %{
               "10" => "2026-06-24T12:00:00Z",
               "11" => "2026-06-24T10:00:00Z",
               "12" => "2026-06-24T11:00:00Z",
               "13" => "2026-06-24T09:00:00Z"
             }

      assert next.github_comment_issue_updated_at == %{
               "11" => "2026-06-24T12:00:00Z",
               "13" => "2026-06-24T12:00:00Z"
             }
    end
  end
end

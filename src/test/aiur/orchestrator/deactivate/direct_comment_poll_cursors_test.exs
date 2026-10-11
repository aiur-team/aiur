defmodule Aiur.Orchestrator.Deactivate.DirectCommentPollCursorsTest do
  use Aiur.TestSupport

  alias Aiur.AgentQueueStore
  alias Aiur.Events.Exchange
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.CommentPolling

  import Aiur.OrchestratorDeactivateSupport

  describe "issue.commented firehose reactivation (subscriber wiring)" do
    test "direct comment poll skips unchanged human-review issues" do
      parent = self()
      updated_at = "2026-06-24T12:00:00Z"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      issue = %Issue{
        id: "57",
        identifier: "57",
        state: "human-review",
        updated_at: datetime!(updated_at)
      }

      request_fun = fn %{url: url} ->
        if String.contains?(url, "/pulls?") do
          {:ok, %{status: 200, body: []}}
        else
          send(parent, {:unexpected_comment_request, url})
          {:ok, %{status: 200, body: []}}
        end
      end

      state = %Orchestrator.State{
        running: %{},
        github_comments_since: %{"57" => "2026-06-24T11:59:59Z"},
        github_comment_issue_updated_at: %{"57" => updated_at}
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging", "rework", "ci-wait"] -> {:ok, [issue]} end
        )

      assert next.github_comments_since == %{"57" => "2026-06-24T11:59:59Z"}
      assert next.github_comment_issue_updated_at == %{"57" => updated_at}
      # The synchronous poll return proves all eligible requests were issued.
      refute_received {:unexpected_comment_request, _url}
    end

    test "direct comment poll checks unchanged human-review issue when open PR changed" do
      parent = self()
      issue_updated_at = "2026-06-24T12:00:00Z"
      pr_updated_at = "2026-06-24T12:03:00Z"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      issue = %Issue{
        id: "57",
        identifier: "57",
        state: "human-review",
        updated_at: datetime!(issue_updated_at)
      }

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/57/comments?") ->
            send(parent, :issue_comments_requested)
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls?") ->
            send(parent, {:unexpected_pull_request_lookup, url})
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/issues/61/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls/61/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls/61/reviews") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/graphql") ->
            empty_review_threads_response()
        end
      end

      state = %Orchestrator.State{
        running: %{},
        github_comments_since: %{"57" => "2026-06-24T11:59:59Z"},
        github_comment_issue_updated_at: %{"57" => issue_updated_at}
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging", "rework", "ci-wait"] -> {:ok, [issue]} end,
          review_pull_request_fetcher: fn "57" -> {:ok, %{"number" => 61, "updated_at" => pr_updated_at}} end
        )

      receive_barrier(:issue_comments_requested)
      # The synchronous poll return proves target discovery is complete.
      refute_received {:unexpected_pull_request_lookup, _url}

      assert next.github_comment_issue_updated_at == %{
               "57" => "issue=#{issue_updated_at};pr=#{pr_updated_at}"
             }
    end

    test "direct comment poll prefers unknown human-review targets before capped PR lookups" do
      parent = self()
      updated_at = "2026-06-24T12:00:00Z"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      issues =
        for id <- ~w(10 11) do
          %Issue{
            id: id,
            identifier: id,
            state: "human-review",
            updated_at: datetime!(updated_at)
          }
        end

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/11/comments?") ->
            send(parent, {:issue_comments_requested, "11"})
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/pulls?") ->
            send(parent, {:pulls_requested, url})
            {:ok, %{status: 200, body: []}}
        end
      end

      state = %Orchestrator.State{
        running: %{},
        github_comments_since: %{
          "10" => "2026-06-24T09:00:00Z",
          "11" => "2026-06-24T10:00:00Z"
        },
        github_comment_issue_updated_at: %{"10" => updated_at}
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging", "rework", "ci-wait"] -> {:ok, issues} end,
          human_review_comment_target_limit: 1,
          max_concurrency: 1
        )

      # The capped target issues a single open-pull-request listing read; the
      # `head=<owner>:aiur/<n>` probe that used to precede it is gone.
      receive_barrier({:pulls_requested, pulls_11})
      receive_barrier({:issue_comments_requested, "11"})
      # The synchronous poll return is the barrier for both request streams.
      refute_received {:pulls_requested, _}
      refute_received {:issue_comments_requested, _}

      refute String.contains?(pulls_11, "head=")
      assert String.contains?(pulls_11, "state=open")
      assert String.contains?(pulls_11, "per_page=100")

      assert next.github_comment_issue_updated_at == %{
               "10" => updated_at,
               "11" => updated_at
             }
    end

    test "human-review target failure does not stop running target cursor advancement" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      human_review_issue = %Issue{
        id: "57",
        identifier: "57",
        state: "human-review",
        updated_at: datetime!("2026-06-24T12:00:00Z")
      }

      :ok = Exchange.subscribe("ticket.42.issue.commented")

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/42/comments?") ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "id" => 4203,
                   "body" => "running target still advances",
                   "updated_at" => "2026-06-24T12:03:00Z",
                   "user" => %{"login" => "its-everdred"}
                 }
               ]
             }}

          String.contains?(url, "/issues/57/comments?") ->
            {:error, :timeout}

          String.contains?(url, "/pulls?") ->
            {:ok, %{status: 200, body: []}}
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
        github_comments_since: %{
          "42" => "2026-06-24T11:00:00Z",
          "57" => "2026-06-24T11:00:00Z"
        }
      }

      next =
        CommentPolling.poll_github_comments(state,
          repo: "owner/repo",
          request_fun: request_fun,
          review_issue_fetcher: fn ["human-review", "merging", "rework", "ci-wait"] -> {:ok, [human_review_issue]} end,
          max_concurrency: 1
        )

      assert next.github_comments_since == %{
               "42" => "2026-06-24T12:02:59Z",
               "57" => "2026-06-24T11:00:00Z"
             }

      assert next.github_comment_issue_updated_at == %{}
      assert next.github_poll_delays == %{}
      receive_barrier({:event, %{topic: "ticket.42.issue.commented", message: "running target still advances"}})
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "direct comment poll preserves cursor when human-review target refresh fails" do
      parent = self()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      :ok = Exchange.subscribe("ticket.42.issue.commented")

      request_fun = fn %{url: url} ->
        send(parent, {:unexpected_comment_request, url})

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
          review_issue_fetcher: fn ["human-review", "merging", "rework", "ci-wait"] -> {:error, :tracker_down} end
        )

      assert next.github_comments_since == "2026-06-24T11:00:00Z"
      # The synchronous poll return proves both request and publish paths have
      # finished for this cycle.
      refute_received {:unexpected_comment_request, _url}
      refute_received {:event, _event}
    after
      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "keeps the active runner while fencing a trusted comment as rework" do
      issue_id = "issue-issue-commented-3"
      issue_identifier = "7"
      previous_memory_recipient = Application.get_env(:aiur, :memory_tracker_recipient)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        Application.put_env(:aiur, :memory_tracker_recipient, self())

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: nil,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "in-progress", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        event = %{
          id: 70_003,
          topic: "ticket.#{issue_identifier}.issue.commented",
          author_trusted?: true,
          comment: %{body: "Please rework this head"}
        }

        assert {:noreply, next} =
                 Orchestrator.handle_info(
                   {:event, event},
                   state
                 )

        # The active runner remains the sole workspace writer, while the
        # concrete queued comment opens a rework fence until provider receipt.
        assert map_size(next.running) == 1
        assert next.running[issue_id].pid == nil
        assert next.running[issue_id].ref == nil
        assert next.running[issue_id].control.status == :working
        assert next.running[issue_id].issue.state == "rework"

        assert %{pending_item_ids: pending_ids, authoritative_state: "rework"} =
                 next.running[issue_id].lifecycle_fence

        assert MapSet.size(pending_ids) == 1
        [item_id] = MapSet.to_list(pending_ids)
        item = AgentQueueStore.get(next.queue_store, item_id)
        assert item.status == :pending
        assert item.delivery.priority == :now
        assert item.delivery.interrupt_requested == true
        assert item.body.events == [event]
        receive_barrier({:memory_tracker_state_update, ^issue_id, "rework"})
      after
        if previous_memory_recipient do
          Application.put_env(:aiur, :memory_tracker_recipient, previous_memory_recipient)
        else
          Application.delete_env(:aiur, :memory_tracker_recipient)
        end
      end
    end
  end
end

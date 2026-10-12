defmodule Aiur.Orchestrator.Deactivate.CommandScanTest do
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.CommandScan

  import Aiur.OrchestratorDeactivateSupport

  describe "per-comment command scan (one-off /aiur or @bot trigger)" do
    test "a trusted /aiur review comment on an unlabeled PR emits the pr#-keyed event" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        tracker_bot_account: "aiur-bot",
        pr_watch_enabled: true,
        pr_watch_command_prefix: "/aiur"
      )

      trust_authors!(["its-everdred"])

      :ok = Exchange.subscribe("ticket.733.pr.review_comment")

      # A REVIEW (line) comment — the primary "live review partner" case. The
      # PR number is derived from `pull_request_url`, NOT from any PR fetch.
      review_command = %{
        "id" => 90_001,
        "body" => "/aiur fix the nil case",
        "updated_at" => "2026-06-25T02:00:00Z",
        "user" => %{"login" => "its-everdred"},
        "pull_request_url" => "https://api.github.com/repos/owner/repo/pulls/733"
      }

      state = %Orchestrator.State{running: %{}, github_command_scan_since: "2026-06-25T00:00:00Z"}

      next =
        CommandScan.scan_pr_commands(state,
          repo: "owner/repo",
          command_scan_review_comment_fetcher: fn _opts -> {:ok, [review_command]} end,
          command_scan_issue_comment_fetcher: fn _opts -> {:ok, []} end
        )

      receive_barrier(
        {:event,
         %{
           topic: "ticket.733.pr.review_comment",
           source: :github,
           author_trusted?: true,
           message: "/aiur fix the nil case",
           issue_number: "733"
         }}
      )

      # The scan cursor advanced past the handled comment (−1s rewind), so the
      # same comment will not re-fire next cycle — the one-off guarantee.
      assert next.github_command_scan_since == "2026-06-25T01:59:59Z"
    after
      restore_trust!(codeowners_state())

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "a @<bot_account> mention in a PR conversation comment emits the reactivation event" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        tracker_bot_account: "aiur-bot",
        pr_watch_enabled: true
      )

      trust_authors!(["its-everdred"])

      :ok = Exchange.subscribe("ticket.734.pr.review_comment")

      # A conversation comment on a PR — `issue_url` gives the number and the
      # `/pull/` in `html_url` confirms it's a PR (not a plain issue).
      mention_comment = %{
        "id" => 90_002,
        "body" => "could you take a look @aiur-bot?",
        "updated_at" => "2026-06-25T03:00:00Z",
        "user" => %{"login" => "its-everdred"},
        "issue_url" => "https://api.github.com/repos/owner/repo/issues/734",
        "html_url" => "https://github.com/owner/repo/pull/734#issuecomment-90002"
      }

      CommandScan.scan_pr_commands(
        %Orchestrator.State{running: %{}, github_command_scan_since: "2026-06-25T00:00:00Z"},
        repo: "owner/repo",
        command_scan_review_comment_fetcher: fn _opts -> {:ok, []} end,
        command_scan_issue_comment_fetcher: fn _opts -> {:ok, [mention_comment]} end
      )

      receive_barrier({:event, %{topic: "ticket.734.pr.review_comment", source: :github}})
    after
      restore_trust!(codeowners_state())

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "a /aiur on a plain (non-PR) issue is out of scope — no event" do
      parent = self()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        tracker_bot_account: "aiur-bot",
        pr_watch_enabled: true
      )

      trust_authors!(["its-everdred"])

      :ok = Exchange.subscribe("ticket.736.pr.review_comment")

      # A plain ISSUE comment: `html_url` contains `/issues/`, not `/pull/`, so
      # the PR-number derivation returns nil and the comment is dropped.
      issue_comment = %{
        "id" => 90_020,
        "body" => "/aiur fix this",
        "updated_at" => "2026-06-25T05:00:00Z",
        "user" => %{"login" => "its-everdred"},
        "issue_url" => "https://api.github.com/repos/owner/repo/issues/736",
        "html_url" => "https://github.com/owner/repo/issues/736#issuecomment-90020"
      }

      CommandScan.scan_pr_commands(
        %Orchestrator.State{running: %{}, github_command_scan_since: "2026-06-25T00:00:00Z"},
        repo: "owner/repo",
        command_scan_review_comment_fetcher: fn _opts -> {:ok, []} end,
        command_scan_issue_comment_fetcher: fn _opts -> {:ok, [issue_comment]} end
      )
      |> tap(fn _ -> send(parent, :scan_done) end)

      receive_barrier(:scan_done)
      # scan_done is sent after scan_pr_commands/2 returns, which is the
      # publication barrier for this synchronous command scan.
      refute_received {:event, %{topic: "ticket.736.pr.review_comment"}}
    after
      restore_trust!(codeowners_state())

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "an untrusted author's /aiur is ignored (no event); the bot's own command is dropped" do
      parent = self()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        tracker_bot_account: "aiur-bot",
        pr_watch_enabled: true
      )

      # `its-everdred` is trusted; `stranger` is not. The bot is also trusted
      # (self-include) but must be dropped by the self-loop gate.
      trust_authors!(["its-everdred", "aiur-bot"])

      :ok = Exchange.subscribe("ticket.735.pr.review_comment")

      review_comments = [
        %{
          "id" => 90_010,
          "body" => "/aiur do the thing",
          "updated_at" => "2026-06-25T04:00:00Z",
          "user" => %{"login" => "stranger"},
          "pull_request_url" => "https://api.github.com/repos/owner/repo/pulls/735"
        },
        %{
          "id" => 90_011,
          "body" => "/aiur status",
          "updated_at" => "2026-06-25T04:01:00Z",
          "user" => %{"login" => "aiur-bot"},
          "pull_request_url" => "https://api.github.com/repos/owner/repo/pulls/735"
        }
      ]

      CommandScan.scan_pr_commands(
        %Orchestrator.State{running: %{}, github_command_scan_since: "2026-06-25T00:00:00Z"},
        repo: "owner/repo",
        command_scan_review_comment_fetcher: fn _opts -> {:ok, review_comments} end,
        command_scan_issue_comment_fetcher: fn _opts -> {:ok, []} end
      )
      |> tap(fn _ -> send(parent, :scan_done) end)

      # Neither the untrusted /aiur nor the bot's own /aiur produces a dispatch.
      receive_barrier(:scan_done)
      # scan_done follows the completed synchronous scan and therefore proves
      # the ignored commands cannot publish later.
      refute_received {:event, %{topic: "ticket.735.pr.review_comment"}}
    after
      restore_trust!(codeowners_state())

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end

    test "pr_watch disabled produces no scan and no events" do
      parent = self()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        tracker_bot_account: "aiur-bot"
      )

      state = %Orchestrator.State{running: %{}, github_command_scan_since: "2026-06-25T00:00:00Z"}

      next =
        CommandScan.scan_pr_commands(state,
          repo: "owner/repo",
          command_scan_review_comment_fetcher: fn _opts ->
            send(parent, :unexpected_command_scan_fetch)
            {:ok, []}
          end,
          command_scan_issue_comment_fetcher: fn _opts ->
            send(parent, :unexpected_command_scan_fetch)
            {:ok, []}
          end
        )

      # Feature off: the fetchers are never invoked and state is untouched.
      assert next == state
      # scan_pr_commands/2 returned through the disabled feature gate.
      refute_received :unexpected_command_scan_fetch
    end

    test "the command scan is bounded by distinct commanded PRs and the drop is logged" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        tracker_bot_account: "aiur-bot",
        pr_watch_enabled: true
      )

      trust_authors!(["its-everdred"])

      # Four distinct commanded PRs surface in one cursor window; the cap keeps
      # the lowest 2 PR numbers and logs the 2 dropped.
      for pr <- 1..4, do: Exchange.subscribe("ticket.#{pr}.pr.review_comment")

      review_comments =
        for n <- 1..4 do
          %{
            "id" => 90_100 + n,
            "body" => "/aiur handle this",
            "updated_at" => "2026-06-25T0#{n}:00:00Z",
            "user" => %{"login" => "its-everdred"},
            "pull_request_url" => "https://api.github.com/repos/owner/repo/pulls/#{n}"
          }
        end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          CommandScan.scan_pr_commands(
            %Orchestrator.State{running: %{}, github_command_scan_since: "2026-06-25T00:00:00Z"},
            repo: "owner/repo",
            command_scan_pull_request_limit: 2,
            command_scan_review_comment_fetcher: fn _opts -> {:ok, review_comments} end,
            command_scan_issue_comment_fetcher: fn _opts -> {:ok, []} end
          )
        end)

      # The two lowest-numbered PRs fire; the other two are capped out.
      receive_barrier({:event, %{topic: "ticket.1.pr.review_comment"}})
      receive_barrier({:event, %{topic: "ticket.2.pr.review_comment"}})
      # capture_log/1 returns after the synchronous bounded scan and all of its
      # publications, so capped targets cannot arrive after this point.
      refute_received {:event, %{topic: "ticket.3.pr.review_comment"}}
      refute_received {:event, %{topic: "ticket.4.pr.review_comment"}}

      assert log =~ "scan_pr_commands capped"
      assert log =~ "dropped=2"
    after
      restore_trust!(codeowners_state())

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end
  end
end

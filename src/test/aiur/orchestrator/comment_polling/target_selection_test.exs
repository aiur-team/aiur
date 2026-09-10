defmodule Aiur.Orchestrator.CommentPolling.TargetSelectionTest do
  use Aiur.TestSupport

  alias Aiur.{Issue, Workflow}
  alias Aiur.Orchestrator.CommentPolling.TargetSelection
  alias Aiur.Orchestrator.State

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent",
      pr_watch_enabled: true
    )

    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_token) end)

    :ok
  end

  test "combines running, review, and watched PR targets without changing metadata" do
    issue_updated_at = "2026-07-11T01:00:00Z"
    pr_updated_at = "2026-07-11T02:00:00Z"
    review_pr = %{"number" => 61, "updated_at" => pr_updated_at}
    watch_pr = %{"number" => 99, "state" => "open"}

    state = %State{
      running: %{"running-42" => %{identifier: "42"}},
      github_comments_since: %{},
      github_comment_issue_updated_at: %{}
    }

    opts = [
      review_issue_fetcher: fn ["human-review", "merging", "rework"] ->
        {:ok, [%Issue{id: "57", identifier: "57", state: "human-review", updated_at: issue_updated_at}]}
      end,
      review_pull_request_fetcher: fn "57" -> {:ok, review_pr} end,
      watch_pull_request_fetcher: fn "agent:watch" -> {:ok, [watch_pr]} end
    ]

    assert {:ok, ["42", "57", "99"], [review_target], [watch_target]} =
             TargetSelection.github_comment_poll_targets(state, opts)

    assert review_target == %{
             target: "57",
             issue_updated_at: issue_updated_at,
             updated_at: "issue=#{issue_updated_at};pr=#{pr_updated_at}",
             open_pull_request: review_pr
           }

    assert watch_target == %{target: "99", open_pull_request: watch_pr}
  end

  # #2601: the live failure. Ticket #164 / PR #178 took a body-only
  # CHANGES_REQUESTED review on one head, reworked to head `f4e6944`, and then
  # took a SECOND body-only CHANGES_REQUESTED review on that newer head. The
  # aggregate `reviewDecision` never moved (it was already sticky from the
  # first review), and the ticket sat in `agent:rework` with no live provider —
  # so the only thing that could re-derive the second review was the `/reviews`
  # read, and target discovery excluded `rework` from the states it polls.
  #
  # Both heads are modelled so the assertion is about the ticket's *state*
  # rather than about the review being new: phase one (human-review) already
  # passed before this fix; phase two (rework) is the one that regressed.
  test "keeps a ticket in agent:rework as a review-submission target across successive heads" do
    first_head_review_at = "2026-09-10T00:10:30Z"
    second_head_review_at = "2026-09-10T00:46:36Z"

    poll_targets = fn issue_state, pr_updated_at ->
      state = %State{
        running: %{},
        github_comments_since: %{},
        github_comment_issue_updated_at: %{}
      }

      opts = [
        review_issue_fetcher: fn states ->
          # The rework state has to be in the tracker query itself; a filter
          # applied after the fetch would never see the ticket at all.
          assert "rework" in states

          {:ok, [%Issue{id: "164", identifier: "164", state: issue_state, updated_at: pr_updated_at}]}
        end,
        review_pull_request_fetcher: fn "164" ->
          {:ok, %{"number" => 178, "updated_at" => pr_updated_at}}
        end,
        watch_pull_request_fetcher: fn "agent:watch" -> {:ok, []} end
      ]

      TargetSelection.github_comment_poll_targets(state, opts)
    end

    assert {:ok, ["164"], [%{target: "164"}], []} =
             poll_targets.("human-review", first_head_review_at)

    # The ticket is now `agent:rework` with its rework turn finished. It must
    # still be a review-submission target, or the second review is invisible.
    assert {:ok, ["164"], [%{target: "164"}], []} =
             poll_targets.("rework", second_head_review_at)
  end

  test "stops target assembly when review issue refresh fails" do
    parent = self()

    opts = [
      review_issue_fetcher: fn ["human-review", "merging", "rework"] -> {:error, :tracker_down} end,
      watch_pull_request_fetcher: fn _label ->
        send(parent, :unexpected_watch_fetch)
        {:ok, []}
      end
    ]

    assert {:error, :tracker_down} =
             TargetSelection.github_comment_poll_targets(%State{}, opts)

    refute_receive :unexpected_watch_fetch
  end

  test "merges cursors and remembers only successful review targets" do
    assert TargetSelection.merge_comment_cursors(
             %{"42" => "old", "57" => "keep"},
             %{"42" => "new"}
           ) == %{"42" => "new", "57" => "keep"}

    assert TargetSelection.merge_comment_cursors("legacy", %{"42" => "new"}) == %{
             "42" => "new"
           }

    review_targets = [
      %{target: "57", updated_at: "reviewed"},
      %{target: "58", updated_at: "failed"},
      %{target: "59", updated_at: nil}
    ]

    errors = [{"58", {:issue_comments, :timeout}}]

    assert TargetSelection.remember_polled_human_review_targets(
             %{"42" => "existing"},
             review_targets,
             errors
           ) == %{"42" => "existing", "57" => "reviewed"}
  end

  test "merges selected PR metadata into existing poll options" do
    existing_pr = %{"number" => 42}
    review_pr = %{"number" => 61}

    opts = [open_pull_requests_by_target: %{"42" => existing_pr}]

    targets = [
      %{target: "57", open_pull_request: review_pr},
      %{target: "58"}
    ]

    result = TargetSelection.put_open_pull_requests_by_target(opts, targets)

    assert Keyword.fetch!(result, :open_pull_requests_by_target) == %{
             "42" => existing_pr,
             "57" => review_pr
           }
  end
end

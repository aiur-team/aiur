defmodule Aiur.Orchestrator.HumanReviewTest do
  # `use Aiur.TestSupport` expands to `use ExUnit.Case` without `async: true`;
  # these tests mutate the global `human_review_ready_verifier` env and cannot
  # race async cases.
  use Aiur.TestSupport

  import ExUnit.CaptureLog

  alias Aiur.Issue
  alias Aiur.Orchestrator.{HumanReview, State}

  test "recognizes the human review state" do
    assert HumanReview.human_review_state?("human-review")
    refute HumanReview.human_review_state?("todo")
  end

  defp setup_verifier(verifier_fun) do
    previous = Application.get_env(:aiur, :human_review_ready_verifier)
    Application.put_env(:aiur, :human_review_ready_verifier, verifier_fun)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:aiur, :human_review_ready_verifier)
      else
        Application.put_env(:aiur, :human_review_ready_verifier, previous)
      end
    end)
  end

  # The gate's only genuine reviewer verdict: unaddressed review-thread comments
  # on an unapproved pull request.
  defp unverified_review_threads_error do
    {:error,
     {:unverified_review_threads,
      %{
        issue_number: "2075",
        pr_number: 42,
        review_thread_ids: ["PRRT_1"],
        comment_ids: ["PRRC_1"],
        count: 1
      }}}
  end

  defp human_review_issue do
    %Issue{id: "2075", identifier: "repo#2075", state: "human-review", title: "t", labels: ["agent:human-review"]}
  end

  # #2075: a human-review ticket that fails its ready-verification reverts to
  # `agent:rework` — but only when an open PR exists, because `rework` means
  # "work exists and was rejected". With no open PR there is nothing a reviewer
  # rejected, so the honest restore is `todo` (make it dispatchable again, no
  # verdict). The revert is only ever driven by a genuine reviewer verdict
  # (`:unverified_review_threads`); an operational failure defers instead.
  test "a genuine unaddressed-thread verdict with no open PR reverts to todo, never rework" do
    setup_verifier(fn _issue_id -> unverified_review_threads_error() end)
    issue = human_review_issue()

    log =
      capture_log(fn ->
        state =
          HumanReview.maybe_deactivate_human_review_issue(%State{}, issue, rework_opts: [open_pr_fetcher: fn _issue_key -> {:ok, nil} end])

        assert state == %State{}
      end)

    assert log =~ "reverting to todo"
    refute log =~ "reverting to rework"
  end

  test "a genuine unaddressed-thread verdict with an open PR reverts to rework" do
    # Control: with an open PR the reviewer verdict is real, so the revert is
    # to `rework`, not `todo`.
    setup_verifier(fn _issue_id -> unverified_review_threads_error() end)
    issue = human_review_issue()

    log =
      capture_log(fn ->
        HumanReview.maybe_deactivate_human_review_issue(%State{}, issue, rework_opts: [open_pr_fetcher: fn _issue_key -> {:ok, %{number: 42}} end])
      end)

    assert log =~ "reverting to rework"
    refute log =~ "reverting to todo"
  end

  # #2400: every error the gate can return other than `:unverified_review_threads`
  # is an infrastructure or operational fault, not a reviewer verdict — the
  # open-PR search or viewer-login fetch failed (rate limit, 5xx, timeout, auth),
  # or the threads read could not be classified. Reverting to `rework` on any of
  # those strands a healthy PR in a state whose rework turn has nothing to fix —
  # the addressed stale-CHANGES_REQUESTED loop #1756 keeps re-raising (#2400), as
  # the daemon did to #2361 when its transient gate fetch error was treated as a
  # verdict. These must *defer* (the ticket stays in `human-review` and the next
  # poll re-verifies) rather than revert to `rework` or `todo`.
  test "a non-verdict gate error defers even when an open PR exists" do
    setup_verifier(fn _issue_id -> {:error, {:github, :http, %{status: 500}}} end)
    issue = human_review_issue()

    log =
      capture_log(fn ->
        state =
          HumanReview.maybe_deactivate_human_review_issue(%State{}, issue, rework_opts: [open_pr_fetcher: fn _issue_key -> {:ok, %{number: 42}} end])

        assert state == %State{}
      end)

    assert log =~ "verification deferred"
    refute log =~ "reverting to rework"
    refute log =~ "reverting to todo"
  end

  test "a non-verdict gate error defers even with no open PR" do
    setup_verifier(fn _issue_id -> {:error, {:github_graphql_errors, [%{"type" => "FORBIDDEN"}]}} end)
    issue = human_review_issue()

    log =
      capture_log(fn ->
        state =
          HumanReview.maybe_deactivate_human_review_issue(%State{}, issue, rework_opts: [open_pr_fetcher: fn _issue_key -> {:ok, nil} end])

        assert state == %State{}
      end)

    assert log =~ "verification deferred"
    refute log =~ "reverting to rework"
    refute log =~ "reverting to todo"
  end

  # #2409: a local GitHub budget hold on the ready-verification (the guard
  # throttling a resource for a bounded window, surfaced raw as
  # `{:aiur, :locally_held, hold}` by `Transport.uncached_quota_request`) is a
  # transient infrastructure fault, not a reviewer verdict. It must *defer* the
  # transition — the ticket stays in `human-review` and the next poll re-verifies
  # — never revert to `rework`, which would strand a healthy PR in a state whose
  # rework turn has nothing to fix (the daemon did exactly that to #2409 when its
  # verification hit a hold).
  test "a local budget hold on the ready-verification defers, never reverts" do
    hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 30, :second)}
    setup_verifier(fn _issue_id -> {:error, {:aiur, :locally_held, hold}} end)
    issue = human_review_issue()

    log =
      capture_log(fn ->
        state =
          HumanReview.maybe_deactivate_human_review_issue(%State{}, issue, rework_opts: [open_pr_fetcher: fn _issue_key -> {:ok, %{number: 42}} end])

        assert state == %State{}
      end)

    assert log =~ "verification deferred"
    refute log =~ "reverting to rework"
    refute log =~ "reverting to todo"
  end
end

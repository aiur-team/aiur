defmodule Aiur.Orchestrator.CommentPolling.ReconcileTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.CommentPolling
  alias Aiur.Orchestrator.CommentPolling.TargetSelection
  alias Aiur.Orchestrator.State

  test "duplicate webhook hints coalesce while polling is frozen" do
    hint = %{kind: :review_thread, ticket: "42", action: "unresolved"}
    state = %State{poll_frozen: true}

    state = CommentPolling.request_reconcile(state, hint)
    state = CommentPolling.request_reconcile(state, hint)

    assert state.github_comment_reconcile_targets == MapSet.new(["42"])
    assert state.github_comment_poll == nil
  end

  test "a hint received during an in-flight poll remains queued for a follow-up" do
    ref = make_ref()

    state = %State{
      github_comment_poll: %{
        ref: ref,
        started_at_ms: System.monotonic_time(:millisecond),
        abandon_after_ms: 60_000
      }
    }

    state = CommentPolling.request_reconcile(state, %{kind: :review_thread, ticket: "43"})

    assert state.github_comment_reconcile_targets == MapSet.new(["43"])
    refute_received :run_github_comment_reconcile

    state = CommentPolling.apply_async(state, ref, {:error, :test_finished})

    assert state.github_comment_reconcile_targets == MapSet.new(["43"])
    assert_received :run_github_comment_reconcile
  end

  test "a failed poll requeues the targets it claimed" do
    ref = make_ref()

    state = %State{
      github_comment_poll: %{ref: ref, reconcile_targets: MapSet.new(["42"])}
    }

    state = CommentPolling.apply_async(state, ref, {:error, :setup_deadline_exceeded})

    assert state.github_comment_reconcile_targets == MapSet.new(["42"])
  end

  test "a partial poll requeues only failed claimed targets" do
    ref = make_ref()

    state = %State{
      github_comment_poll: %{ref: ref, reconcile_targets: MapSet.new(["42", "43"])}
    }

    payload =
      {:ok, %{}, [],
       {["42", "43"],
        {:ok,
         %{
           since: %{},
           etags: %{},
           count: 0,
           errors: [{"43", :timeout}],
           pr_review_seen_at: %{}
         }}}}

    state = CommentPolling.apply_async(state, ref, payload)

    assert state.github_comment_reconcile_targets == MapSet.new(["43"])
  end

  test "a successful bounded poll immediately drains queued remainder" do
    ref = make_ref()

    state = %State{
      github_comment_poll: %{ref: ref, reconcile_targets: MapSet.new(["42"])},
      github_comment_reconcile_targets: MapSet.new(["43"])
    }

    payload =
      {:ok, %{}, [],
       {["42"],
        {:ok,
         %{
           since: %{},
           etags: %{},
           count: 0,
           errors: [],
           pr_review_seen_at: %{}
         }}}}

    state = CommentPolling.apply_async(state, ref, payload)

    assert state.github_comment_reconcile_targets == MapSet.new(["43"])
    assert_received :run_github_comment_reconcile
  end

  test "forced reconcile targets bypass ordinary discovery omission and caps" do
    state = %State{
      github_comment_reconcile_targets: MapSet.new(["42", "43"]),
      running: %{"running" => %{identifier: "7"}}
    }

    opts = [
      review_issue_fetcher: fn _states -> {:ok, []} end,
      watch_pull_request_fetcher: fn _label -> {:ok, []} end,
      human_review_comment_target_limit: 1,
      watch_comment_target_limit: 1
    ]

    assert {:ok, targets, [], []} = TargetSelection.github_comment_poll_targets(state, opts)
    assert MapSet.new(targets) == MapSet.new(["7", "42", "43"])
  end

  test "webhook reconcile selection polls only forced targets" do
    state = %State{
      github_comment_reconcile_targets: MapSet.new(["42", "43"]),
      github_comment_issue_list_cache: %{etag: "held"},
      running: %{"running" => %{identifier: "7"}}
    }

    opts = [
      reconcile_only: true,
      review_issue_fetcher: fn _states -> flunk("review discovery must not run") end,
      watch_pull_request_fetcher: fn _label -> flunk("watch discovery must not run") end
    ]

    assert {:ok, targets, [], []} = TargetSelection.github_comment_poll_targets(state, opts)
    assert MapSet.new(targets) == MapSet.new(["42", "43"])

    assert {:ok, cached_targets, [], [], %{etag: "held"}} =
             TargetSelection.github_comment_poll_targets_with_cache(state, opts)

    assert MapSet.new(cached_targets) == MapSet.new(["42", "43"])
    assert TargetSelection.max_comment_poll_target_count(state, opts) == 2
  end

  test "webhook reconcile selection claims deterministic bounded batches" do
    state = %State{
      github_comment_reconcile_targets: MapSet.new(["44", "42", "43"]),
      github_comment_issue_list_cache: %{etag: "held"}
    }

    opts = [reconcile_only: true, reconcile_target_limit: 2]

    assert {:ok, ["42", "43"], [], []} = TargetSelection.github_comment_poll_targets(state, opts)
    assert TargetSelection.reconcile_targets_for_poll(state, opts) == MapSet.new(["42", "43"])
    assert TargetSelection.max_comment_poll_target_count(state, opts) == 2
  end

  test "irrelevant reconcile hints do not enter the comment queue" do
    state = %State{poll_frozen: true}
    assert CommentPolling.request_reconcile(state, %{kind: :ci, ticket: "42"}) == state
    assert CommentPolling.request_reconcile(state, %{kind: :review_thread, ticket: nil}) == state
  end
end

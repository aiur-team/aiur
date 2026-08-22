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

  test "an expired targeted poll reclaims its target before replacement" do
    test_pid = self()

    hanging_request = fn _request ->
      send(test_pid, {:targeted_comment_poll_started, self()})
      Process.sleep(:infinity)
    end

    opts = [
      tracker_kind: "github",
      repo: "owner/repo",
      reconcile_only: true,
      comment_batch_fetcher: fn _targets, _opts -> {:ok, %{"42" => %{open_pull_request: nil}}} end,
      request_fun: hanging_request
    ]

    state = %State{github_comment_reconcile_targets: MapSet.new(["42"])}

    first_state = state |> CommentPolling.start_async(opts) |> await_async_started()
    assert_receive {:targeted_comment_poll_started, first_pid}, 5_000
    assert first_state.github_comment_reconcile_targets == MapSet.new()

    expired_at = System.monotonic_time(:millisecond) - first_state.github_comment_poll.abandon_after_ms - 1
    expired_state = put_in(first_state.github_comment_poll.started_at_ms, expired_at)
    second_state = expired_state |> CommentPolling.start_async(opts) |> await_async_started()

    wait_until(fn -> not Process.alive?(first_pid) end)
    assert second_state.github_comment_poll.reconcile_targets == MapSet.new(["42"])
    assert second_state.github_comment_reconcile_targets == MapSet.new()
    assert_receive {:targeted_comment_poll_started, second_pid}, 5_000
    assert second_pid != first_pid

    CommentPolling.terminate_poll(second_state.github_comment_poll)
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

  defp await_async_started(%State{github_comment_poll: %{ref: ref, owner: owner}} = state) do
    receive do
      {:github_comment_poll_started, ^ref, ^owner, pid} ->
        CommentPolling.apply_async_started(state, ref, owner, pid)
    after
      5_000 -> flunk("comment poll did not start")
    end
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(fun, 0), do: assert(fun.(), "condition did not become true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end

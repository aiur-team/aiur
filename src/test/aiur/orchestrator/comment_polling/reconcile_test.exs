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

  test "a burst retains every identity while each poll claim stays bounded" do
    state = %State{poll_frozen: true}
    opts = [reconcile_target_limit: 2]

    state = CommentPolling.request_reconcile(state, %{kind: :review_thread, ticket: "43"}, opts)
    state = CommentPolling.request_reconcile(state, %{kind: :review_thread, ticket: "42"}, opts)
    state = CommentPolling.request_reconcile(state, %{kind: :review_thread, ticket: "44"}, opts)

    assert state.github_comment_reconcile_targets == MapSet.new(["42", "43", "44"])

    targeted_poll =
      CommentPolling.start_async(%{state | poll_frozen: false},
        tracker_kind: "github",
        reconcile_only: true,
        reconcile_target_limit: 2
      )

    assert MapSet.size(targeted_poll.github_comment_poll.reconcile_targets) == 2
    assert MapSet.size(targeted_poll.github_comment_reconcile_targets) == 1

    CommentPolling.terminate_poll(targeted_poll.github_comment_poll)

    next_poll =
      CommentPolling.start_async(
        %{targeted_poll | github_comment_poll: nil, github_comment_reconcile_timer: nil},
        tracker_kind: "github",
        reconcile_only: true,
        reconcile_target_limit: 2
      )

    assert next_poll.github_comment_poll.reconcile_targets == MapSet.new(["44"])
    assert next_poll.github_comment_reconcile_targets == MapSet.new()
    CommentPolling.terminate_poll(next_poll.github_comment_poll)
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
    assert state.github_comment_reconcile_timer == nil

    state = CommentPolling.apply_async(state, ref, {:error, :test_finished})

    assert state.github_comment_reconcile_targets == MapSet.new(["43"])
    assert_receive {:run_github_comment_reconcile, token}
    assert token == state.github_comment_reconcile_timer.token
  end

  test "a failed poll requeues the targets it claimed" do
    ref = make_ref()

    state = %State{
      github_comment_poll: %{ref: ref, reconcile_targets: MapSet.new(["42"])}
    }

    state = CommentPolling.apply_async(state, ref, {:error, :setup_deadline_exceeded})

    assert state.github_comment_reconcile_targets == MapSet.new(["42"])
  end

  test "failed reconcile retry honors the active GitHub delay" do
    ref = make_ref()

    state = %State{
      github_comment_poll: %{ref: ref, reconcile_targets: MapSet.new(["42"])},
      github_poll_delays: %{comments: 60_000}
    }

    assert CommentPolling.reconcile_retry_delay_ms(state) == 60_000

    state = CommentPolling.apply_async(state, ref, {:error, :setup_deadline_exceeded})

    assert state.github_comment_reconcile_targets == MapSet.new(["42"])
    assert state.github_comment_reconcile_timer.delay_ms == 60_000
    refute_received :run_github_comment_reconcile
  end

  test "new webhook admission honors active backoff and coalesces its timer" do
    state = %State{github_poll_delays: %{comments: 60_000}}
    hint = %{kind: :review_thread, ticket: "42"}

    state = CommentPolling.request_reconcile(state, hint)
    token = state.github_comment_reconcile_timer.token

    state = CommentPolling.request_reconcile(state, hint)

    assert state.github_comment_reconcile_timer.token == token
    assert state.github_comment_reconcile_timer.delay_ms == 60_000
    refute_received {:run_github_comment_reconcile, _token}
  end

  test "a larger backoff token-fences an earlier reconcile timer" do
    state =
      %State{github_poll_delays: %{comments: 30_000}}
      |> CommentPolling.request_reconcile(%{kind: :review_thread, ticket: "42"})

    old_token = state.github_comment_reconcile_timer.token

    state =
      state
      |> put_in([Access.key(:github_poll_delays), :comments], 60_000)
      |> CommentPolling.request_reconcile(%{kind: :review_thread, ticket: "43"})

    refute state.github_comment_reconcile_timer.token == old_token
    assert state.github_comment_reconcile_timer.delay_ms == 60_000
    assert CommentPolling.run_scheduled_reconcile(state, old_token) == state
  end

  test "the current timer token claims the queued reconciliation batch" do
    token = make_ref()

    state = %State{
      github_comment_reconcile_targets: MapSet.new(["42"]),
      github_comment_reconcile_timer: %{token: token, timer_ref: nil, delay_ms: 0, due_at_ms: 0}
    }

    state = CommentPolling.run_scheduled_reconcile(state, token, tracker_kind: "github")

    assert state.github_comment_reconcile_timer == nil
    assert state.github_comment_poll.reconcile_targets == MapSet.new(["42"])
    assert state.github_comment_reconcile_targets == MapSet.new()
    CommentPolling.terminate_poll(state.github_comment_poll)
  end

  test "a failed attempt restarts the full backoff even when its delay is unchanged" do
    state =
      %State{github_poll_delays: %{comments: 60_000}}
      |> CommentPolling.request_reconcile(%{kind: :review_thread, ticket: "42"})

    old_token = state.github_comment_reconcile_timer.token
    poll_ref = make_ref()

    state =
      state
      |> Map.put(:github_comment_poll, %{ref: poll_ref, reconcile_targets: MapSet.new(["42"])})
      |> CommentPolling.apply_async(poll_ref, {:error, :setup_deadline_exceeded})

    refute state.github_comment_reconcile_timer.token == old_token
    assert state.github_comment_reconcile_timer.delay_ms == 60_000
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
    assert_receive {:run_github_comment_reconcile, token}
    assert token == state.github_comment_reconcile_timer.token
  end

  test "completion clears an obsolete timer after an ordinary poll claims the target" do
    ref = make_ref()
    token = make_ref()

    state = %State{
      github_comment_poll: %{ref: ref, reconcile_targets: MapSet.new(["42"])},
      github_comment_reconcile_timer: %{token: token, timer_ref: nil, delay_ms: 60_000, due_at_ms: 0}
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

    assert state.github_comment_reconcile_targets == MapSet.new()
    assert state.github_comment_reconcile_timer == nil
  end

  test "an expired targeted poll reclaims its target and backs off before replacement" do
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
    second_state = CommentPolling.start_async(expired_state, opts)

    wait_until(fn -> not Process.alive?(first_pid) end)
    assert second_state.github_comment_poll == nil
    assert second_state.github_comment_reconcile_targets == MapSet.new(["42"])
    refute_received :run_github_comment_reconcile
  end

  test "owner DOWN reclaims its target beside a newly queued target" do
    poll_pid = spawn(fn -> Process.sleep(:infinity) end)
    poll_monitor_ref = Process.monitor(poll_pid)
    owner_monitor_ref = make_ref()

    state = %State{
      github_comment_poll: %{
        owner_monitor_ref: owner_monitor_ref,
        pid: poll_pid,
        monitor_ref: poll_monitor_ref,
        reconcile_targets: MapSet.new(["42"])
      },
      github_comment_reconcile_targets: MapSet.new(["43"])
    }

    assert {:handled, state} = CommentPolling.apply_async_down(state, owner_monitor_ref)
    assert state.github_comment_poll == nil
    assert state.github_comment_reconcile_targets == MapSet.new(["42", "43"])
    assert state.github_comment_reconcile_timer.delay_ms >= 5_000
    refute Process.alive?(poll_pid)
  end

  test "poll DOWN reclaims its target beside a newly queued target" do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    owner_monitor_ref = Process.monitor(owner)
    monitor_ref = make_ref()
    ref = make_ref()

    state = %State{
      github_comment_poll: %{
        ref: ref,
        owner: owner,
        owner_monitor_ref: owner_monitor_ref,
        monitor_ref: monitor_ref,
        reconcile_targets: MapSet.new(["42"])
      },
      github_comment_reconcile_targets: MapSet.new(["43"])
    }

    assert {:handled, state} = CommentPolling.apply_async_down(state, monitor_ref)
    assert state.github_comment_poll == nil
    assert state.github_comment_reconcile_targets == MapSet.new(["42", "43"])
    assert state.github_comment_reconcile_timer.delay_ms >= 5_000

    Process.exit(owner, :kill)
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

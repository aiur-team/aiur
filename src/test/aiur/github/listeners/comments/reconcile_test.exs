defmodule Aiur.GitHub.Listeners.Comments.ReconcileTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Listeners.Comments.{Cursor, Driver, Input, TargetSelection}

  test "duplicate webhook hints coalesce while polling is frozen" do
    input = input(0, [])
    hint = %{kind: :review_thread, ticket: "42", action: "unresolved"}
    state = %Cursor{}

    state = Driver.request_reconcile(state, input, hint, poll_frozen: true) |> finish(input)
    state = Driver.request_reconcile(state, input, hint, poll_frozen: true) |> finish(input)

    assert state.reconcile_targets == MapSet.new(["42"])
    assert state.poll == nil
  end

  test "a burst retains every identity while each poll claim stays bounded" do
    input = input(0, [])
    state = %Cursor{}
    opts = [reconcile_target_limit: 2, poll_frozen: true]

    state = Driver.request_reconcile(state, input, %{kind: :review_thread, ticket: "43"}, opts) |> finish(input)
    state = Driver.request_reconcile(state, input, %{kind: :review_thread, ticket: "42"}, opts) |> finish(input)
    state = Driver.request_reconcile(state, input, %{kind: :review_thread, ticket: "44"}, opts) |> finish(input)

    assert state.reconcile_targets == MapSet.new(["42", "43", "44"])

    targeted_poll =
      Driver.start_async(state, input,
        tracker_kind: "github",
        reconcile_only: true,
        reconcile_target_limit: 2
      )
      |> finish(input)

    assert MapSet.size(targeted_poll.poll.reconcile_targets) == 2
    assert MapSet.size(targeted_poll.reconcile_targets) == 1

    Driver.terminate_poll(targeted_poll.poll)

    next_poll =
      Driver.start_async(
        %{targeted_poll | poll: nil, reconcile_timer: nil},
        input,
        tracker_kind: "github",
        reconcile_only: true,
        reconcile_target_limit: 2
      )
      |> finish(input)

    assert next_poll.poll.reconcile_targets == MapSet.new(["44"])
    assert next_poll.reconcile_targets == MapSet.new()
    Driver.terminate_poll(next_poll.poll)
  end

  test "a hint received during an in-flight poll remains queued for a follow-up" do
    input = input(0, [])
    ref = make_ref()

    state = %Cursor{
      poll: %{
        ref: ref,
        started_at_ms: System.monotonic_time(:millisecond),
        abandon_after_ms: 60_000
      }
    }

    state = Driver.request_reconcile(state, input, %{kind: :review_thread, ticket: "43"}) |> finish(input)

    assert state.reconcile_targets == MapSet.new(["43"])
    assert state.reconcile_timer == nil

    state = Driver.apply_async(state, input, ref, {:error, :test_finished}) |> finish(input)

    assert state.reconcile_targets == MapSet.new(["43"])
    assert_receive {:run_github_comment_reconcile, token}, 1000
    assert token == state.reconcile_timer.token
  end

  test "a failed poll requeues the targets it claimed" do
    input = input(0, [])
    ref = make_ref()

    state = %Cursor{
      poll: %{ref: ref, reconcile_targets: MapSet.new(["42"])}
    }

    state = Driver.apply_async(state, input, ref, {:error, :setup_deadline_exceeded}) |> finish(input)

    assert state.reconcile_targets == MapSet.new(["42"])
  end

  test "failed reconcile retry honors the active GitHub delay" do
    input = input(60_000, [])
    ref = make_ref()

    state = %Cursor{
      poll: %{ref: ref, reconcile_targets: MapSet.new(["42"])}
    }

    assert Driver.reconcile_retry_delay_ms(input) == 60_000

    state = Driver.apply_async(state, input, ref, {:error, :setup_deadline_exceeded}) |> finish(input)

    assert state.reconcile_targets == MapSet.new(["42"])
    assert state.reconcile_timer.delay_ms == 60_000
    refute_received :run_github_comment_reconcile
  end

  test "new webhook admission honors active backoff and coalesces its timer" do
    input = input(60_000, [])
    state = %Cursor{}
    hint = %{kind: :review_thread, ticket: "42"}

    state = Driver.request_reconcile(state, input, hint) |> finish(input)
    token = state.reconcile_timer.token

    state = Driver.request_reconcile(state, input, hint) |> finish(input)

    assert state.reconcile_timer.token == token
    assert state.reconcile_timer.delay_ms == 60_000
    refute_received {:run_github_comment_reconcile, _token}
  end

  test "a larger backoff token-fences an earlier reconcile timer" do
    input = input(30_000, [])

    state =
      %Cursor{} |> Driver.request_reconcile(input, %{kind: :review_thread, ticket: "42"}) |> finish(input)

    old_token = state.reconcile_timer.token
    input = %{input | next_github_delay_ms: 60_000}

    state =
      state |> Driver.request_reconcile(input, %{kind: :review_thread, ticket: "43"}) |> finish(input)

    refute state.reconcile_timer.token == old_token
    assert state.reconcile_timer.delay_ms == 60_000
    assert Driver.run_scheduled_reconcile(state, input, old_token) |> finish(input) == state
  end

  test "the current timer token claims the queued reconciliation batch" do
    input = input(0, [])
    token = make_ref()

    state = %Cursor{
      reconcile_targets: MapSet.new(["42"]),
      reconcile_timer: %{token: token, timer_ref: nil, delay_ms: 0, due_at_ms: 0}
    }

    state = Driver.run_scheduled_reconcile(state, input, token, tracker_kind: "github") |> finish(input)

    assert state.reconcile_timer == nil
    assert state.poll.reconcile_targets == MapSet.new(["42"])
    assert state.reconcile_targets == MapSet.new()
    Driver.terminate_poll(state.poll)
  end

  test "a failed attempt restarts the full backoff even when its delay is unchanged" do
    input = input(60_000, [])

    state =
      %Cursor{} |> Driver.request_reconcile(input, %{kind: :review_thread, ticket: "42"}) |> finish(input)

    old_token = state.reconcile_timer.token
    poll_ref = make_ref()

    state =
      state |> Map.put(:poll, %{ref: poll_ref, reconcile_targets: MapSet.new(["42"])}) |> Driver.apply_async(input, poll_ref, {:error, :setup_deadline_exceeded}) |> finish(input)

    refute state.reconcile_timer.token == old_token
    assert state.reconcile_timer.delay_ms == 60_000
  end

  test "a partial poll requeues only failed claimed targets" do
    input = input(0, [])
    ref = make_ref()

    state = %Cursor{
      poll: %{ref: ref, reconcile_targets: MapSet.new(["42", "43"])}
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

    state = Driver.apply_async(state, input, ref, payload) |> finish(input)

    assert state.reconcile_targets == MapSet.new(["43"])
  end

  test "a successful bounded poll immediately drains queued remainder" do
    input = input(0, [])
    ref = make_ref()

    state = %Cursor{
      poll: %{ref: ref, reconcile_targets: MapSet.new(["42"])},
      reconcile_targets: MapSet.new(["43"])
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

    state = Driver.apply_async(state, input, ref, payload) |> finish(input)

    assert state.reconcile_targets == MapSet.new(["43"])
    assert_receive {:run_github_comment_reconcile, token}, 1000
    assert token == state.reconcile_timer.token
  end

  test "completion clears an obsolete timer after an ordinary poll claims the target" do
    input = input(0, [])
    ref = make_ref()
    token = make_ref()

    state = %Cursor{
      poll: %{ref: ref, reconcile_targets: MapSet.new(["42"])},
      reconcile_timer: %{token: token, timer_ref: nil, delay_ms: 60_000, due_at_ms: 0}
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

    state = Driver.apply_async(state, input, ref, payload) |> finish(input)

    assert state.reconcile_targets == MapSet.new()
    assert state.reconcile_timer == nil
  end

  test "an expired targeted poll honors active backoff before replacement" do
    input = input(60_000, [])
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
      token: "test-gh-token",
      request_fun: hanging_request
    ]

    state = %Cursor{
      reconcile_targets: MapSet.new(["42"])
    }

    first_state = state |> Driver.start_async(input, opts) |> finish(input) |> await_async_started(input)
    assert_receive {:targeted_comment_poll_started, first_pid}, 5_000
    assert first_state.reconcile_targets == MapSet.new()

    expired_at = System.monotonic_time(:millisecond) - first_state.poll.abandon_after_ms - 1
    expired_state = put_in(first_state.poll.started_at_ms, expired_at)
    second_state = Driver.start_async(expired_state, input, opts) |> finish(input)

    wait_until(fn -> not Process.alive?(first_pid) end)
    assert second_state.poll == nil
    assert second_state.reconcile_targets == MapSet.new(["42"])
    assert second_state.reconcile_timer.delay_ms == 60_000
    refute_received :run_github_comment_reconcile
  end

  test "owner DOWN reclaims its target beside a newly queued target" do
    input = input(0, [])
    poll_pid = spawn(fn -> Process.sleep(:infinity) end)
    poll_monitor_ref = Process.monitor(poll_pid)
    owner_monitor_ref = make_ref()

    state = %Cursor{
      poll: %{
        owner_monitor_ref: owner_monitor_ref,
        pid: poll_pid,
        monitor_ref: poll_monitor_ref,
        reconcile_targets: MapSet.new(["42"])
      },
      reconcile_targets: MapSet.new(["43"])
    }

    state = Driver.apply_async_down(state, input, owner_monitor_ref) |> finish(input)
    assert state.poll == nil
    assert state.reconcile_targets == MapSet.new(["42", "43"])
    assert state.reconcile_timer.delay_ms >= 5_000
    refute Process.alive?(poll_pid)
  end

  test "poll DOWN reclaims its target beside a newly queued target" do
    input = input(0, [])
    owner = spawn(fn -> Process.sleep(:infinity) end)
    owner_monitor_ref = Process.monitor(owner)
    monitor_ref = make_ref()
    ref = make_ref()

    state = %Cursor{
      poll: %{
        ref: ref,
        owner: owner,
        owner_monitor_ref: owner_monitor_ref,
        monitor_ref: monitor_ref,
        reconcile_targets: MapSet.new(["42"])
      },
      reconcile_targets: MapSet.new(["43"])
    }

    state = Driver.apply_async_down(state, input, monitor_ref) |> finish(input)
    assert state.poll == nil
    assert state.reconcile_targets == MapSet.new(["42", "43"])
    assert state.reconcile_timer.delay_ms >= 5_000

    Process.exit(owner, :kill)
  end

  test "forced reconcile targets bypass ordinary discovery omission and caps" do
    input = input(0, ["7"])

    state = %Cursor{
      reconcile_targets: MapSet.new(["42", "43"])
    }

    opts = [
      review_issue_fetcher: fn _states -> {:ok, []} end,
      watch_pull_request_fetcher: fn _label -> {:ok, []} end,
      human_review_comment_target_limit: 1,
      watch_comment_target_limit: 1
    ]

    assert {:ok, targets, [], []} = TargetSelection.github_comment_poll_targets(state, input, opts)
    assert MapSet.new(targets) == MapSet.new(["7", "42", "43"])
  end

  test "webhook reconcile selection polls only forced targets" do
    input = input(0, ["7"])

    state = %Cursor{
      reconcile_targets: MapSet.new(["42", "43"]),
      issue_list_cache: %{etag: "held"}
    }

    opts = [
      reconcile_only: true,
      review_issue_fetcher: fn _states -> flunk("review discovery must not run") end,
      watch_pull_request_fetcher: fn _label -> flunk("watch discovery must not run") end
    ]

    assert {:ok, targets, [], []} = TargetSelection.github_comment_poll_targets(state, input, opts)
    assert MapSet.new(targets) == MapSet.new(["42", "43"])

    assert {:ok, cached_targets, [], [], %{etag: "held"}} =
             TargetSelection.github_comment_poll_targets_with_cache(state, input, opts)

    assert MapSet.new(cached_targets) == MapSet.new(["42", "43"])
    assert TargetSelection.max_comment_poll_target_count(state, input, opts) == 2
  end

  test "webhook reconcile selection claims deterministic bounded batches" do
    input = input(0, [])

    state = %Cursor{
      reconcile_targets: MapSet.new(["44", "42", "43"]),
      issue_list_cache: %{etag: "held"}
    }

    opts = [reconcile_only: true, reconcile_target_limit: 2]

    assert {:ok, ["42", "43"], [], []} = TargetSelection.github_comment_poll_targets(state, input, opts)
    assert TargetSelection.reconcile_targets_for_poll(state, input, opts) == MapSet.new(["42", "43"])
    assert TargetSelection.max_comment_poll_target_count(state, input, opts) == 2
  end

  test "irrelevant reconcile hints do not enter the comment queue" do
    input = input(0, [])
    state = %Cursor{}
    assert Driver.request_reconcile(state, input, %{kind: :ci, ticket: "42"}) |> finish(input) == state
    assert Driver.request_reconcile(state, input, %{kind: :review_thread, ticket: nil}) |> finish(input) == state
  end

  defp await_async_started(%Cursor{poll: %{ref: ref, owner: owner}} = state, input) do
    receive do
      {:github_comment_poll_started, ^ref, ^owner, pid} ->
        Driver.apply_async_started(state, input, ref, owner, pid) |> finish(input)
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

  defp input(delay, targets) do
    %Input{running_targets: targets, running_titles: %{}, ownership_key: nil, next_github_delay_ms: delay}
  end

  defp finish({cursor, outcome}, input), do: Driver.finish(cursor, input, outcome, [])
end

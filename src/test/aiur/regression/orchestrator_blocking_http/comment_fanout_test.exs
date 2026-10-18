defmodule Aiur.Regression.OrchestratorBlockingHttp.CommentFanoutTest do
  use Aiur.TestSupport

  import Aiur.OrchestratorBlockingHttpSupport

  alias Aiur.GitHub.Transport
  alias Aiur.Orchestrator.CommentPolling

  @crashing_owner_name :orchestrator_blocking_http_crashing_owner
  @stopping_owner_name :orchestrator_blocking_http_stopping_owner

  setup do
    setup_orchestrator()
  end

  describe "the comment poll fan-out" do
    # The second capture on #1837, and a different call site from the reported
    # one: host load 1.68, quota healthy, and the Orchestrator parked in
    # `Task.Supervised.stream_reduce/7` under `Dispatcher.do_maybe_dispatch/1`
    # with a 5,729-message mailbox while `status` and `agents` timed out. A
    # per-request deadline cannot bound an awaited fan-out — N targets cost N
    # deadlines — so the poll has to leave the callback altogether.
    test "is issued, not awaited, by the process that starts it" do
      test_pid = self()

      hanging_fetcher = fn _states ->
        send(test_pid, :comment_poll_started)
        Process.sleep(:infinity)
      end

      state = %Aiur.Orchestrator.State{running: %{}}

      {elapsed_us, next_state} =
        :timer.tc(fn ->
          CommentPolling.start_async(state, comment_poll_opts(hanging_fetcher))
        end)

      next_state = await_async_started(next_state)
      assert_receive :comment_poll_started, 5_000
      assert div(elapsed_us, 1_000) < 1_000
      assert %{ref: ref} = next_state.github_comment_poll
      assert is_reference(ref)
    end

    test "does not start a second poll while one is outstanding" do
      test_pid = self()

      hanging_fetcher = fn _states ->
        send(test_pid, :comment_poll_started)
        Process.sleep(:infinity)
      end

      opts = comment_poll_opts(hanging_fetcher)

      state = CommentPolling.start_async(%Aiur.Orchestrator.State{running: %{}}, opts)
      state = await_async_started(state)
      assert_receive :comment_poll_started, 5_000

      assert CommentPolling.start_async(state, opts).github_comment_poll == state.github_comment_poll
      refute_receive :comment_poll_started, 500
    end

    test "derived abandonment bound covers bounded setup and every target wave" do
      running = Map.new(1..13, fn issue -> {to_string(issue), %{identifier: to_string(issue)}} end)

      opts =
        comment_poll_opts(fn _states -> {:ok, []} end) ++
          [setup_timeout: 300_000, max_concurrency: 4, timeout: 60_000, human_review_comment_target_limit: 1, watch_comment_target_limit: 1]

      state = CommentPolling.start_async(%Aiur.Orchestrator.State{running: running}, opts)

      # Thirteen running targets plus the two configured review/watch slots
      # need four complete waves. The independently bounded setup phase and a
      # scheduling margin are additive, so neither legitimate setup work nor
      # the final target wave can be mistaken for a hung poll.
      assert state.github_comment_poll.abandon_after_ms > 300_000 + 4 * 60_000
      CommentPolling.terminate_poll(state.github_comment_poll)
    end

    test "slow setup and the final target wave remain owned until their combined bound", %{orchestrator: pid} do
      test_pid = self()

      review_issue_fetcher = fn _states ->
        send(test_pid, {:slow_setup_started, self()})

        receive do
          :finish_slow_setup -> {:ok, []}
        end
      end

      request_fun = fn _request ->
        send(test_pid, {:slow_target_started, self()})

        receive do
          :finish_slow_target -> {:ok, %{status: 304, headers: []}}
        end
      end

      setup_timeout = 2_000
      target_timeout = 2_000

      opts =
        comment_poll_opts(review_issue_fetcher) ++
          [
            setup_timeout: setup_timeout,
            max_concurrency: 1,
            timeout: target_timeout,
            human_review_comment_target_limit: 1,
            watch_comment_target_limit: 1,
            comment_batch_fetcher: fn _targets, _opts -> {:ok, %{"57" => %{open_pull_request: nil}}} end,
            request_fun: request_fun
          ]

      :sys.replace_state(pid, fn state ->
        state
        |> Map.put(:running, %{
          "57" => %{
            identifier: "57",
            issue: %Aiur.Issue{id: "57", identifier: "57", state: "in-progress", title: "Slow setup"}
          }
        })
        # This fixture owns exactly one running target plus two configured
        # slots; pending reconciliation from the shared process adds waves.
        |> Map.put(:github_comment_reconcile_targets, MapSet.new())
        |> CommentPolling.start_async(opts)
      end)

      assert_receive {:slow_setup_started, setup_worker}, 5_000
      poll = :sys.get_state(pid).github_comment_poll
      assert poll.abandon_after_ms == setup_timeout + 3 * target_timeout + 30_000

      # Re-entering at the end of the setup allowance must retain the same
      # owned poll; setup's budget cannot be mistaken for target-wave time.
      assert_same_poll_at_elapsed(pid, opts, poll, setup_timeout - 1)
      send(setup_worker, :finish_slow_setup)

      assert_receive {:slow_target_started, target_worker}, 5_000

      # One running target plus the configured review/watch maxima is three
      # complete waves at max_concurrency=1. Even at the end of that combined
      # setup + wave allowance, the replacement path must not run.
      assert_same_poll_at_elapsed(pid, opts, poll, setup_timeout + 3 * target_timeout - 1)
      send(target_worker, :finish_slow_target)

      wait_until(fn -> :sys.get_state(pid).github_comment_poll == nil end)
    end

    test "bounded setup reaps a hanging request descendant before answering" do
      test_pid = self()

      review_issue_fetcher = fn _states ->
        setup_worker = self()

        Transport.off_process_request(%{}, fn ->
          send(test_pid, {:setup_request_started, setup_worker, self()})
          Process.sleep(:infinity)
        end)
      end

      opts = comment_poll_opts(review_issue_fetcher) ++ [setup_timeout: 250]
      state = CommentPolling.start_async(%Aiur.Orchestrator.State{running: %{}}, opts)
      state = await_async_started(state)
      assert_receive {:setup_request_started, setup_worker, request_worker}, 5_000

      assert_receive {:github_comments_polled, _ref, {:error, :setup_deadline_exceeded}}, 2_000
      wait_until(fn -> not Process.alive?(setup_worker) end)
      wait_until(fn -> not Process.alive?(request_worker) end)
      wait_until(fn -> not Process.alive?(state.github_comment_poll.pid) end)
    end

    test "terminates an expired poll before starting its replacement" do
      test_pid = self()

      hanging_fetcher = fn _states ->
        send(test_pid, {:comment_poll_started, self()})
        Process.sleep(:infinity)
      end

      opts = comment_poll_opts(hanging_fetcher)

      # Ownership is registry-scoped; isolate this poll from unrelated tests
      # that also use the default nil snapshot key under coverage load.
      state = CommentPolling.start_async(%Aiur.Orchestrator.State{running: %{}, snapshot_key: self()}, opts)
      state = await_async_started(state)
      assert_receive {:comment_poll_started, first_pid}, 5_000
      first_poll = state.github_comment_poll.pid

      expired_at = System.monotonic_time(:millisecond) - state.github_comment_poll.abandon_after_ms - 1
      expired_state = put_in(state.github_comment_poll.started_at_ms, expired_at)
      next_state = CommentPolling.start_async(expired_state, opts)
      next_state = await_async_started(next_state)

      wait_until(fn -> not Process.alive?(first_pid) end)
      refute Process.alive?(first_poll)
      assert_receive {:comment_poll_started, second_pid}, 5_000
      assert second_pid != first_pid
      assert next_state.github_comment_poll.pid != first_poll
      assert Process.alive?(second_pid)
      CommentPolling.terminate_poll(next_state.github_comment_poll)
    end

    test "terminates target descendants before replacing an expired poll" do
      test_pid = self()

      request_fun = fn _request ->
        target = self()

        Transport.off_process_request(%{}, fn ->
          send(test_pid, {:comment_request_started, target, self()})
          Process.sleep(:infinity)
        end)
      end

      opts = Keyword.put(comment_poll_opts(fn _states -> {:ok, []} end), :request_fun, request_fun)
      state = %Aiur.Orchestrator.State{running: %{"57" => %{identifier: "57"}}}

      first_state = CommentPolling.start_async(state, opts)
      first_state = await_async_started(first_state)
      assert_receive {:comment_request_started, first_target, first_request}, 5_000

      expired_at = System.monotonic_time(:millisecond) - first_state.github_comment_poll.abandon_after_ms - 1
      expired_state = put_in(first_state.github_comment_poll.started_at_ms, expired_at)
      second_state = CommentPolling.start_async(expired_state, opts)
      second_state = await_async_started(second_state)

      wait_until(fn -> not Process.alive?(first_target) end)
      wait_until(fn -> not Process.alive?(first_request) end)
      assert_receive {:comment_request_started, second_target, second_request}, 5_000
      assert second_target != first_target

      Process.exit(second_state.github_comment_poll.pid, :kill)
      wait_until(fn -> not Process.alive?(second_request) end)
    end

    test "termination does not hang after a completed poll waits for release" do
      state = CommentPolling.start_async(%Aiur.Orchestrator.State{running: %{}}, comment_poll_opts(fn _states -> {:ok, []} end))
      state = await_async_started(state)
      poll = state.github_comment_poll

      wait_until(fn -> not Process.alive?(poll.pid) end)
      assert Process.alive?(poll.owner)

      terminator = Task.async(fn -> CommentPolling.terminate_poll(poll) end)
      assert Task.await(terminator, 1_000) == :ok
      assert_receive {:github_comments_polled, _ref, _payload}, 1000
    end

    test "termination reaps the poll tree if its owner dies before acknowledging" do
      test_pid = self()

      spawn(fn ->
        poll = spawn(fn -> Process.sleep(:infinity) end)
        monitor_ref = Process.monitor(poll)

        owner =
          spawn(fn ->
            receive do
              {:stop_owned_poll, _caller, _stop_ref} -> exit(:before_ack)
            end
          end)

        send(test_pid, {:before_ack_poll, poll})
        result = CommentPolling.terminate_poll(%{pid: poll, owner: owner, monitor_ref: monitor_ref})
        send(test_pid, {:before_ack_result, result})
      end)

      assert_receive {:before_ack_poll, poll}, 1000
      assert_receive {:before_ack_result, :ok}, 1_000
      refute Process.alive?(poll)
    end

    test "production routing reaps a waiting poll when its owner dies before start", %{orchestrator: pid} do
      assert_owner_death_reaps_poll(pid, :before_start)
    end

    test "production routing reaps a started poll when its owner dies before guarding", %{orchestrator: pid} do
      assert_owner_death_reaps_poll(pid, :after_start_before_guard)
    end

    test "an orchestrator crash reaps its blocked poll and request descendants" do
      name = @crashing_owner_name
      child_id = :crashing_comment_poll_owner
      orchestrator = start_supervised!({Orchestrator, [name: name, initial_poll?: false]}, id: child_id)

      {poll, target, request} = start_blocked_comment_poll(orchestrator)
      owner_ref = Process.monitor(orchestrator)
      Process.exit(orchestrator, :kill)

      assert_receive {:DOWN, ^owner_ref, :process, ^orchestrator, :killed}, 5_000

      wait_until(fn ->
        case Process.whereis(name) do
          pid when is_pid(pid) -> pid != orchestrator
          nil -> false
        end
      end)

      successor = Process.whereis(name)
      {next_poll, _next_target, next_request} = start_blocked_comment_poll(successor)
      refute Process.alive?(poll)
      refute Process.alive?(target)
      refute Process.alive?(request)

      next_state = :sys.get_state(successor)
      CommentPolling.terminate_poll(next_state.github_comment_poll)
      refute Process.alive?(next_poll)
      wait_until(fn -> not Process.alive?(next_request) end)
    end

    test "orderly orchestrator shutdown reaps its blocked poll and request descendants" do
      name = @stopping_owner_name
      child_id = :stopping_comment_poll_owner
      orchestrator = start_supervised!({Orchestrator, [name: name, initial_poll?: false]}, id: child_id)

      {poll, target, request} = start_blocked_comment_poll(orchestrator)
      poll_ref = Process.monitor(poll)
      target_ref = Process.monitor(target)
      request_ref = Process.monitor(request)

      assert :ok = stop_supervised(child_id)

      refute Process.alive?(poll)
      refute Process.alive?(target)
      refute Process.alive?(request)
      assert_receive {:DOWN, ^poll_ref, :process, ^poll, :killed}, 1000
      assert_receive {:DOWN, ^target_ref, :process, ^target, _reason}, 1000
      assert_receive {:DOWN, ^request_ref, :process, ^request, _reason}, 1000
      refute Process.whereis(name)
    end

    test "production result routing preserves a newer shared issue cache", %{orchestrator: pid} do
      test_pid = self()

      review_issue_fetcher = fn _states ->
        send(test_pid, {:comment_target_refresh_started, self()})

        receive do
          :finish_comment_target_refresh -> {:ok, []}
        end
      end

      opts = comment_poll_opts(review_issue_fetcher)

      :sys.replace_state(pid, fn state ->
        state = put_in(state.ci_lifecycle.poll_cache[:issue_list_cache], %{etag: "shared-before"})
        state = %{state | github_comment_issue_list_cache: %{etag: "comments-only"}}
        CommentPolling.start_async(state, opts)
      end)

      assert_receive {:comment_target_refresh_started, worker}, 5_000

      :sys.replace_state(pid, fn state ->
        state = put_in(state.ci_lifecycle.poll_cache[:issue_list_cache], %{etag: "shared-after"})
        %{state | github_comment_issue_list_cache: %{etag: "in-flight-sentinel"}}
      end)

      send(worker, :finish_comment_target_refresh)
      wait_until(fn -> :sys.get_state(pid).github_comment_poll == nil end)

      final_state = :sys.get_state(pid)
      assert final_state.ci_lifecycle.poll_cache[:issue_list_cache] == %{etag: "shared-after"}
      assert final_state.github_comment_issue_list_cache == %{etag: "comments-only"}
    end

    test "production DOWN routing clears a failed comment poll", %{orchestrator: pid} do
      test_pid = self()

      review_issue_fetcher = fn _states ->
        send(test_pid, :comment_target_refresh_crashing)
        exit(:comment_target_refresh_failed)
      end

      :sys.replace_state(pid, fn state ->
        CommentPolling.start_async(state, comment_poll_opts(review_issue_fetcher))
      end)

      assert_receive :comment_target_refresh_crashing, 5_000
      wait_until(fn -> :sys.get_state(pid).github_comment_poll == nil end)
      assert Process.alive?(pid)
    end

    test "drops a straggler from a poll the state is no longer waiting for" do
      state = %Aiur.Orchestrator.State{running: %{}, github_comments_since: %{"57" => "2026-06-24T11:00:00Z"}}

      assert CommentPolling.apply_async(state, make_ref(), {:error, :boom}) == state
    end
  end
end

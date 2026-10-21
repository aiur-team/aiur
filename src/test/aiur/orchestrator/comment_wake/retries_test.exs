defmodule Aiur.Orchestrator.CommentWake.RetriesTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.{CommentWake, State}

  defp base_state do
    %State{
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      queue_store: nil,
      last_polled_issues: %{},
      todo_over_capacity_alert_active: false,
      agent_totals: nil,
      agent_rate_limits: nil,
      codex_totals: nil,
      codex_rate_limits: nil,
      poll_interval_ms: 60_000,
      max_concurrent_agents: nil,
      session_max_concurrent_agents: nil,
      effective_concurrent_agents: nil,
      load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: nil},
      next_poll_due_at_ms: nil,
      poll_check_in_progress: nil,
      tick_timer_ref: nil,
      tick_token: nil,
      initial_dispatch_cycle: false,
      github_connectivity: %{},
      github_poll_delays: %{}
    }
  end

  describe "comment_rework_retry_delay_ms/1" do
    test "returns base delay for attempt 1" do
      assert CommentWake.comment_rework_retry_delay_ms(1) == 2_000
    end

    test "returns larger delay for attempt 2 (exponential backoff)" do
      delay1 = CommentWake.comment_rework_retry_delay_ms(1)
      delay2 = CommentWake.comment_rework_retry_delay_ms(2)
      assert delay1 == 2_000
      assert delay2 == 4_000
    end

    test "delay is 2000-based (at attempt 1 returns base delay)" do
      assert CommentWake.comment_rework_retry_delay_ms(5) == 32_000
    end
  end

  # Regression coverage for #1747. A comment-rework retry chain runs on the
  # long-lived orchestrator for ~60s at the default settings, so a chain that can
  # never succeed keeps emitting warnings long after the work that started it —
  # in CI, straight into whichever unrelated `capture_log` assertion is running.
  describe "retryable_comment_rework_failure?/1" do
    test "a missing GitHub token is permanent, so it must not be retried" do
      refute CommentWake.retryable_comment_rework_failure?(:missing_github_token)
    end

    test "auth and permission classifications are permanent" do
      refute CommentWake.retryable_comment_rework_failure?({:github, :auth, %{status: 401}})
      refute CommentWake.retryable_comment_rework_failure?({:github, :permission, %{status: 403}})
    end

    test "client errors are permanent" do
      refute CommentWake.retryable_comment_rework_failure?({:github_api_status, 404})
      refute CommentWake.retryable_comment_rework_failure?({:github, :http, %{status: 422}})
    end

    test "server errors and transport faults are retryable" do
      assert CommentWake.retryable_comment_rework_failure?({:github_api_status, 502})
      assert CommentWake.retryable_comment_rework_failure?({:github, :http, %{status: 500}})
      assert CommentWake.retryable_comment_rework_failure?({:github, :timeout, %{reason: :timeout}})
      assert CommentWake.retryable_comment_rework_failure?({:github, :dns, %{reason: :nxdomain}})
    end

    test "request timeout and rate limiting stay retryable despite being 4xx" do
      assert CommentWake.retryable_comment_rework_failure?({:github_api_status, 408})
      assert CommentWake.retryable_comment_rework_failure?({:github_api_status, 429})
      assert CommentWake.retryable_comment_rework_failure?({:github, :rate_limited, %{status: 403}})
    end

    test "an unrecognised reason stays retryable" do
      assert CommentWake.retryable_comment_rework_failure?(:something_new)
    end
  end

  describe "comment-rework retry timer lifecycle" do
    defp tracked_retry_state(delay_ms) do
      issue_number = "1747"
      source = "issue comment"
      message = {:retry_comment_rework, issue_number, source, %{}, 2}
      timer_ref = Process.send_after(self(), message, delay_ms)

      state = %{
        base_state()
        | comment_rework_retries: %{
            CommentWake.comment_rework_retry_key(issue_number, source) => {timer_ref, issue_number, source}
          }
      }

      {state, timer_ref}
    end

    test "cancel_comment_rework_retries/1 stops a pending timer and clears tracking" do
      {state, timer_ref} = tracked_retry_state(100)

      cleared = CommentWake.cancel_comment_rework_retries(state)

      assert cleared.comment_rework_retries == %{}
      assert Process.read_timer(timer_ref) == false
      refute_receive {:retry_comment_rework, _issue, _source, _event, _attempt}, 300
    end

    test "cancel_comment_rework_retries/1 drops a retry that already fired" do
      {state, timer_ref} = tracked_retry_state(1)

      # Let the timer fire so its message is sitting in the mailbox: cancelling
      # alone would not stop that delivered retry from being processed.
      wait_until_timer_fired(timer_ref)

      cleared = CommentWake.cancel_comment_rework_retries(state)

      assert cleared.comment_rework_retries == %{}
      refute_received {:retry_comment_rework, _issue, _source, _event, _attempt}
    end

    test "cancel_comment_rework_retries/1 leaves unrelated mailbox messages alone" do
      {state, _timer_ref} = tracked_retry_state(100)
      send(self(), :unrelated_before)

      CommentWake.cancel_comment_rework_retries(state)

      assert_received :unrelated_before
    end

    test "forget_comment_rework_retry/3 drops the ref without cancelling" do
      {state, timer_ref} = tracked_retry_state(5_000)

      forgotten = CommentWake.forget_comment_rework_retry(state, "1747", "issue comment")

      assert forgotten.comment_rework_retries == %{}
      assert is_integer(Process.read_timer(timer_ref))
      Process.cancel_timer(timer_ref)
    end

    test "cancel_comment_rework_retries/1 tolerates a state with no tracked retries" do
      assert CommentWake.cancel_comment_rework_retries(base_state()).comment_rework_retries == %{}
    end

    defp wait_until_timer_fired(timer_ref, attempts \\ 100) do
      cond do
        Process.read_timer(timer_ref) == false -> :ok
        attempts == 0 -> flunk("timer did not fire")
        true -> Process.sleep(5) && wait_until_timer_fired(timer_ref, attempts - 1)
      end
    end
  end

  describe "comment_rework_max_attempts/0" do
    test "returns 5" do
      assert CommentWake.comment_rework_max_attempts() == 5
    end
  end
end

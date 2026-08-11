defmodule Aiur.Regression.OrchestratorDispatchRetryTest do
  use Aiur.TestSupport

  @moduledoc """
  These tests pin `Aiur.Orchestrator` dispatch and retry behavior prior to the
  T-022..T-027 decomposition and must pass unmodified through every extraction wave.
  """

  defmodule RetryPollFailingGitHubClient do
    def preflight_auth, do: :ok

    def fetch_candidate_issues do
      case Application.get_env(:aiur, :retry_poll_failure_test_pid) do
        pid when is_pid(pid) -> send(pid, :retry_poll_fetch_candidate_issues)
        _ -> :ok
      end

      {:error, {:github, :rate_limited, %{status: 403, remaining: 0, reset_at: "2026-08-11T12:00:00Z", retry_after: 60}}}
    end

    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issues_by_states(_states, _opts), do: {:ok, []}
  end

  defp running_entry(issue_id, identifier, status) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{id: issue_id, identifier: identifier, state: "In Progress", title: nil},
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: status},
      session_id: "thread-#{identifier}",
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      started_at: DateTime.utc_now()
    }
  end

  defp start_orchestrator(name) do
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
    pid
  end

  defp base_state(attrs) do
    struct!(
      Orchestrator.State,
      Keyword.merge(
        [
          running: %{},
          claimed: MapSet.new(),
          retry_attempts: %{},
          max_concurrent_agents: 6,
          session_max_concurrent_agents: nil,
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
        ],
        attrs
      )
    )
  end

  defp issue(id, state \\ "todo", attrs \\ []), do: struct!(Issue, Keyword.merge([id: id, identifier: id, title: id, state: state], attrs))

  defp assert_due_in_range(due_at_ms, before_ms, min_delta_ms, max_delta_ms) do
    assert is_integer(due_at_ms)
    assert due_at_ms >= before_ms + min_delta_ms
    assert due_at_ms <= before_ms + max_delta_ms
  end

  defp github_retry_env! do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "its-everdred/aiur",
      tracker_active_states: ["todo", "in-progress"],
      tracker_terminal_states: ["done"],
      max_retry_backoff_ms: 100
    )

    previous_client = Application.get_env(:aiur, :github_client_module)
    previous_pid = Application.get_env(:aiur, :retry_poll_failure_test_pid)
    previous_token = System.get_env("GITHUB_TOKEN")
    Application.put_env(:aiur, :github_client_module, RetryPollFailingGitHubClient)
    Application.put_env(:aiur, :retry_poll_failure_test_pid, self())
    System.put_env("GITHUB_TOKEN", "retry-poll-test-token")

    on_exit(fn ->
      if previous_client,
        do: Application.put_env(:aiur, :github_client_module, previous_client),
        else: Application.delete_env(:aiur, :github_client_module)

      if previous_pid,
        do: Application.put_env(:aiur, :retry_poll_failure_test_pid, previous_pid),
        else: Application.delete_env(:aiur, :retry_poll_failure_test_pid)

      restore_env("GITHUB_TOKEN", previous_token)
    end)
  end

  describe "dispatch gates" do
    test "available slots = cap - (active + paused)" do
      running = %{"active" => running_entry("active", "D1A", :working), "paused" => running_entry("paused", "D1P", :paused)}
      state = base_state(max_concurrent_agents: 2, running: running)
      refute Orchestrator.should_dispatch_issue_for_test(issue("d1"), state)
      assert Orchestrator.should_dispatch_issue_for_test(issue("d1"), %{state | max_concurrent_agents: 3})
    end

    test "load gate holds new dispatch strictly above threshold x schedulers (#465)" do
      assert Orchestrator.load_gate(20.0, 1.5, 12) == :hold
      assert Orchestrator.load_gate(10.0, 1.5, 12) == :dispatch
      assert Orchestrator.load_gate(18.0, 1.5, 12) == :dispatch
      assert Orchestrator.load_gate(:unavailable, 1.5, 12) == :dispatch
    end

    test "load gate disabled via null threshold never reads the load source" do
      previous = Application.get_env(:aiur, :loadavg_source_override)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:aiur, :loadavg_source_override, previous),
          else: Application.delete_env(:aiur, :loadavg_source_override)
      end)

      assert Orchestrator.load_gate(99.0, nil, 12) == :dispatch
      assert Orchestrator.load_gate(99.0, 0.0, 12) == :dispatch
      Application.put_env(:aiur, :loadavg_source_override, fn -> flunk("must not read load when disabled") end)
      assert Orchestrator.read_load(nil) == :unavailable
    end

    test "per-state slot limit gates same-state dispatch" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents_by_state: %{"rework" => 1})
      rework = running_entry("d4-active", "D4A", :working) |> put_in([:issue, Access.key(:state)], "rework")
      state = base_state(max_concurrent_agents: 3, running: %{"d4-active" => rework})

      refute Orchestrator.should_dispatch_issue_for_test(issue("d4-rework", "rework"), state)
      assert Orchestrator.should_dispatch_issue_for_test(issue("d4-todo", "todo"), state)
    end

    test "a claimed issue is not a dispatch candidate" do
      state = base_state(claimed: MapSet.new(["d5"]))
      refute Orchestrator.dispatch_candidate_for_test(issue("d5"), state)
      assert Orchestrator.dispatch_candidate_for_test(issue("d5"), %{state | claimed: MapSet.new()})
    end

    test "a running issue is not a dispatch candidate" do
      state = base_state(running: %{"d6" => running_entry("d6", "D6", :working)})
      refute Orchestrator.dispatch_candidate_for_test(issue("d6"), state)
    end

    test "a todo blocked by a non-terminal blocker is not a candidate; unknown blocker state blocks" do
      state = base_state(max_concurrent_agents: 3)
      blocked = issue("d7", "todo", blocked_by: [%{id: "b1", identifier: "B1", state: "In Progress"}])
      unknown = issue("d7u", "todo", blocked_by: [%{id: "b2", identifier: "B2", state: nil}])
      terminal = issue("d7t", "todo", blocked_by: [%{id: "b3", identifier: "B3", state: "done"}])

      refute Orchestrator.dispatch_candidate_for_test(blocked, state)
      refute Orchestrator.dispatch_candidate_for_test(unknown, state)
      assert Orchestrator.dispatch_candidate_for_test(terminal, state)
    end
  end

  describe "retry budget accounting" do
    test "a stale retry token is dropped" do
      name = Module.concat(__MODULE__, :StaleRetry)
      pid = start_orchestrator(name)
      token = make_ref()

      entry = %{
        attempt: 2,
        retry_token: token,
        timer_ref: nil,
        due_at_ms: System.monotonic_time(:millisecond),
        identifier: "D8",
        error: "boom"
      }

      :sys.replace_state(pid, &%{&1 | retry_attempts: %{"d8" => entry}})

      send(pid, {:retry_issue, "d8", make_ref()})
      assert %{attempt: 2, retry_token: ^token} = :sys.get_state(pid).retry_attempts["d8"]
    end

    test "slot-unavailable retry reschedules as capacity_wait without burning budget (#549/#551)" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", max_concurrent_agents: 1)
      retry_issue = issue("d9", "In Progress", identifier: "D9")
      Application.put_env(:aiur, :memory_tracker_issues, [retry_issue])
      name = Module.concat(__MODULE__, :SlotWaitRetry)
      pid = start_orchestrator(name)
      token = make_ref()
      busy = running_entry("busy", "D9B", :working)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{"busy" => busy},
            claimed: MapSet.new(["d9"]),
            retry_attempts: %{
              "d9" => %{
                attempt: 2,
                retry_token: token,
                timer_ref: nil,
                due_at_ms: System.monotonic_time(:millisecond),
                identifier: "D9",
                error: "agent exited: :response_timeout"
              }
            }
        }
      end)

      before_ms = System.monotonic_time(:millisecond)
      send(pid, {:retry_issue, "d9", token})
      state = :sys.get_state(pid)
      assert %{attempt: 2, due_at_ms: due_at_ms, error: "no available orchestrator slots"} = state.retry_attempts["d9"]
      assert is_reference(state.retry_attempts["d9"].retry_token)
      refute state.retry_attempts["d9"].retry_token == token
      assert_due_in_range(due_at_ms, before_ms, 1_000, 2_000)
      refute Orchestrator.retry_dispatch_ready_for_test(retry_issue, %{state | running: %{"busy" => busy}})
      assert Orchestrator.retry_dispatch_ready_for_test(retry_issue, %{state | running: %{}})
    end

    test "tracker poll failure reschedules as precondition without burning budget (#549/#551)" do
      github_retry_env!()
      name = Module.concat(__MODULE__, :RetryPoll)
      pid = start_orchestrator(name)
      ref = make_ref()
      :sys.replace_state(pid, &%{&1 | running: %{"d10" => %{running_entry("d10", "D10", :working) | ref: ref}}, claimed: MapSet.new(["d10"])})

      send(pid, {:DOWN, ref, :process, self(), :response_timeout})
      assert %{attempt: 1, retry_token: token} = :sys.get_state(pid).retry_attempts["d10"]
      send(pid, {:retry_issue, "d10", token})
      assert %{attempt: 1, retry_poll_failures: 1} = :sys.get_state(pid).retry_attempts["d10"]
    end

    test "a rate-limited retry-poll exhaustion releases the claim, alerts, and schedules automatic re-claim" do
      github_retry_env!()
      name = Module.concat(__MODULE__, :RetryPollExhausted)
      pid = start_orchestrator(name)
      token = make_ref()

      retry = %{
        attempt: 1,
        retry_token: token,
        timer_ref: nil,
        due_at_ms: System.monotonic_time(:millisecond),
        identifier: "D11",
        error: "agent exited: :timeout",
        retry_poll_failures: 2
      }

      :sys.replace_state(pid, &%{&1 | claimed: MapSet.new(["d11"]), retry_attempts: %{"d11" => retry}})

      log =
        capture_log(fn ->
          send(pid, {:retry_issue, "d11", token})
          _ = :sys.get_state(pid)
        end)

      state = :sys.get_state(pid)
      refute Map.has_key?(state.retry_attempts, "d11")
      refute MapSet.member?(state.claimed, "d11")
      assert %{cause: :rate_limit, attempt: 1} = state.auto_resume["d11"]
      assert log =~ "orchestrator.claim_released"
      assert log =~ "reason=rate_limit_exhausted"
      assert log =~ "remaining=0"
      assert log =~ "reset_at=2026-08-11T12:00:00Z"
    end

    test "the claim-released alert names the credential actually used, never the configured bot_account (#1475)" do
      github_retry_env!()

      # `bot_account` is what an operator configured, not proof of who
      # authenticated: under a GitHub App installation token the two differ, and
      # a security-adjacent alert must not present a config value as the
      # credential identity.
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "its-everdred/aiur",
        tracker_active_states: ["todo", "in-progress"],
        tracker_terminal_states: ["done"],
        tracker_bot_account: "configured-not-authenticated",
        max_retry_backoff_ms: 100
      )

      name = Module.concat(__MODULE__, :RetryPollCredentialIdentity)
      pid = start_orchestrator(name)
      token = make_ref()

      retry = %{
        attempt: 1,
        retry_token: token,
        timer_ref: nil,
        due_at_ms: System.monotonic_time(:millisecond),
        identifier: "D11C",
        error: "agent exited: :timeout",
        retry_poll_failures: 2
      }

      :sys.replace_state(pid, &%{&1 | claimed: MapSet.new(["d11c"]), retry_attempts: %{"d11c" => retry}})

      log =
        capture_log(fn ->
          send(pid, {:retry_issue, "d11c", token})
          _ = :sys.get_state(pid)
        end)

      expected_fingerprint =
        "token-sha256:" <> (:crypto.hash(:sha256, "retry-poll-test-token") |> Base.encode16(case: :lower) |> binary_part(0, 12))

      assert log =~ "orchestrator.claim_released"
      assert log =~ "credential=#{expected_fingerprint}"
      refute log =~ "configured-not-authenticated"
      refute log =~ "token_identity="
    end

    test "failure-retry exhaustion moves the ticket to error and releases the claim (#699/#723)" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      Application.put_env(:aiur, :memory_tracker_recipient, self())
      name = Module.concat(__MODULE__, :FailureExhausted)
      pid = start_orchestrator(name)
      ref = make_ref()
      entry = Map.merge(running_entry("d12", "D12", :working), %{ref: ref, retry_attempt: 3})
      :sys.replace_state(pid, &%{&1 | running: %{"d12" => entry}, claimed: MapSet.new(["d12"]), retry_attempts: %{}})

      log =
        capture_log(fn ->
          send(pid, {:DOWN, ref, :process, self(), :boom})
          _ = :sys.get_state(pid)
        end)

      state = :sys.get_state(pid)
      refute Map.has_key?(state.retry_attempts, "d12")
      refute MapSet.member?(state.claimed, "d12")
      assert_receive {:memory_tracker_state_update, "D12", "error"}, 2000
      assert log =~ "agent.retry_exhausted"
    end

    test "normal worker exit schedules a continuation retry at attempt 1" do
      name = Module.concat(__MODULE__, :NormalExit)
      pid = start_orchestrator(name)
      ref = make_ref()
      :sys.replace_state(pid, &%{&1 | running: %{"d13" => %{running_entry("d13", "D13", :working) | ref: ref}}, claimed: MapSet.new(["d13"]), retry_attempts: %{}})

      before_ms = System.monotonic_time(:millisecond)
      send(pid, {:DOWN, ref, :process, self(), :normal})
      state = :sys.get_state(pid)
      refute Map.has_key?(state.running, "d13")
      assert MapSet.member?(state.completed, "d13")
      assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts["d13"]
      assert_due_in_range(due_at_ms, before_ms, 500, 1_100)
    end

    test "abnormal worker exit schedules exponential failure backoff" do
      name = Module.concat(__MODULE__, :AbnormalExit)
      pid = start_orchestrator(name)
      ref = make_ref()
      entry = Map.merge(running_entry("d14", "D14", :working), %{ref: ref, retry_attempt: 2})
      :sys.replace_state(pid, &%{&1 | running: %{"d14" => entry}, claimed: MapSet.new(["d14"]), retry_attempts: %{}})

      before_ms = System.monotonic_time(:millisecond)
      send(pid, {:DOWN, ref, :process, self(), :boom})
      state = :sys.get_state(pid)
      assert %{attempt: 3, due_at_ms: due_at_ms, error: "agent exited: :boom"} = state.retry_attempts["d14"]
      assert_due_in_range(due_at_ms, before_ms, 39_500, 40_500)
    end
  end
end

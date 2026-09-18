defmodule Aiur.Codex.UsageLimitTest do
  # Regression for #2737: the account-wide Codex usage limit left Khala #15
  # paused as `waiting_for_human` with no fallback and no resume.
  use Aiur.TestSupport

  alias Aiur.AgentRunner.TurnAlerts
  alias Aiur.Codex.CodingAgent, as: CodexAgent
  alias Aiur.ModelAvailability
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{RateLimitFallback, WaitingReason}

  # The refusal as Codex CLI 0.154.0 recorded it for turn 01a0b3bc on
  # 2026-09-18T09:20:37Z (task_complete.error in the rollout). The app-server
  # sends it as an ErrorNotification and as the failed turn's TurnError.
  @banner "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Sep 21st, 2026 6:26 PM."
  @thread "01a0b3b2-f413-7bf1-a724-c492e3c9be3c"
  @observed_turn "01a0b3bc-83ca-7970-bbe2-eed2e9eeb3fc"
  @observed_at ~U[2026-09-18 09:20:37Z]
  # The rollout's rate-limit snapshot: primary window at 100 percent with
  # resetsAt 1790040385. The pause takes this exact value, not the text.
  @resets_at_epoch 1_790_040_385
  @reset_at "2026-09-22T01:26:25Z"
  # With no exhausted window known, the text "Sep 21st, 2026 6:26 PM" (PDT) is
  # rounded up to the end of its minute.
  @text_reset_at "2026-09-22T01:27:00Z"
  @turn_timeout_ms 400

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-codex-usage-limit")
    workspace = Path.join(Config.workspace_root(), "KHALA-15")
    binary = Path.join(root, "fake-codex")
    File.mkdir_p!(root)
    File.mkdir_p!(workspace)
    File.write!(binary, fake_app_server(Path.join(root, "codex.trace")))
    File.chmod!(binary, 0o755)
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "codex",
      command: "#{binary} app-server",
      agent_turn_timeout_ms: @turn_timeout_ms,
      # Khala's app-server host printed the reset text in Pacific time.
      codex_reset_time_zone: "America/Los_Angeles"
    )

    {:ok, session} = CodexAgent.start_session(workspace, clock: fn -> @observed_at end)
    on_exit(fn -> CodexAgent.stop_session(session) end)

    issue = %Issue{id: "15", identifier: "15", title: "KHA-106", state: "In Progress", selected_backend: "codex"}
    %{session: session, issue: issue, workspace: workspace}
  end

  test "the observed refusal pauses with the numeric reset, no retry, and resumes at the reset", ctx do
    %{session: session, issue: issue, workspace: workspace} = ctx
    assert session.reset_time_zone == "America/Los_Angeles"
    test_pid = self()
    on_message = fn message -> send(test_pid, {:agent_message, message.event}) end

    # 1. The rate-limit snapshot marks the window used up; the
    # ErrorNotification (willRetry false) then ends the turn as a pause.
    assert {:paused, pause} = CodexAgent.run_turn(session, "review", issue, on_message: on_message)
    assert pause.kind == :usage_limit_exhausted
    assert pause.reason =~ "usage limit"
    assert pause.reset_hint == "Sep 21st, 2026 6:26 PM"
    assert pause.reset_at == @reset_at
    refute_received {:agent_message, :turn_ended_with_error}

    # 2. The paused turn's own failed completion arrives late, inside the
    # resumed turn. It belongs to the first pause and must not pause again.
    assert {:ok, _session} = CodexAgent.run_turn(session, "resume", issue, on_message: on_message)

    # 3. A failed turn/completed with the TurnError alone is the same pause.
    # A snapshot below 100 percent cleared the numeric reset first, so the
    # reset comes from the text, rounded up to the end of its minute.
    assert {:paused, turn_pause} = CodexAgent.run_turn(session, "next", issue, on_message: on_message)
    assert turn_pause.kind == :usage_limit_exhausted
    assert turn_pause.reason == "turn/completed: " <> @banner
    assert turn_pause.reset_at == @text_reset_at

    # 4. Assistant and tool text that quotes the refusal is not a refusal.
    assert {:ok, _session} = CodexAgent.run_turn(session, "quote the banner", issue, on_message: on_message)

    # 5. A turn that goes silent is surfaced within the no-progress bound.
    started = System.monotonic_time(:millisecond)
    assert {:error, :turn_timeout} = CodexAgent.run_turn(session, "silent", issue, on_message: on_message)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= @turn_timeout_ms and elapsed < @turn_timeout_ms + 2_000

    # The runner's pause boundary records the limit with a real deadline.
    TurnAlerts.maybe_emit_usage_limit_alert(issue, workspace, nil, Map.put(pause, :backend, "codex"))
    assert get_in(ModelAvailability.load(), ["backends", "codex", "reset_at"]) == @reset_at
    refute ModelAvailability.available?("codex")

    # The orchestrator side of the incident. At 08:51:51 the agent paused
    # itself (agent_pause_request). At 08:52:12 QueueDrain resumed the worker
    # for a queued Executor message and reported :working with no request id.
    entry = %{
      issue: issue,
      identifier: issue.identifier,
      pid: self(),
      ref: make_ref(),
      started_at: DateTime.utc_now(),
      retry_attempt: 2,
      paused_reason: :agent_pause_request,
      control: %{status: :paused, can_interrupt: true}
    }

    state = %Orchestrator.State{running: %{issue.id => entry}, max_concurrent_agents: 6}
    assert waiting_reason(entry) == :waiting_for_human
    assert {:noreply, working} = Orchestrator.handle_info({:worker_control_state, issue.id, :working}, state)
    refute Map.has_key?(working.running[issue.id], :paused_reason)
    assert waiting_reason(working.running[issue.id]) == :active

    # At 09:20:37 the Codex usage limit paused the worker.
    assert {:noreply, paused} = Orchestrator.handle_info({:worker_control_state, issue.id, :paused, pause}, working)
    paused_entry = paused.running[issue.id]
    assert paused_entry.paused_reason == :usage_limit_exhausted
    assert paused_entry.usage_limit_reset_at == @reset_at
    assert paused_entry.retry_attempt == 2
    assert paused.retry_attempts == state.retry_attempts
    assert waiting_reason(paused_entry) == :provider_limited
    assert WaitingReason.render(:provider_limited) == "provider_limited"

    {:ok, reset, 0} = DateTime.from_iso8601(@reset_at)
    opts = [primary_backend: "codex", fallback_backend: nil, current_backend: "codex", marker_label: "agent:rate-limit-fallback", state: %{"backends" => %{}}]

    # A configured fallback takes the ticket; without one it holds until the reset.
    assert RateLimitFallback.decide(paused_entry, issue, Keyword.merge(opts, fallback_backend: "claude", now: DateTime.add(reset, -1))) ==
             :engage

    assert RateLimitFallback.reconcile(paused, Keyword.put(opts, :now, DateTime.add(reset, -1))) == paused
    refute_received {:resume_agent, _request_id}
    resumed = RateLimitFallback.reconcile(paused, Keyword.put(opts, :now, reset))
    assert_received {:resume_agent, _request_id}
    assert resumed.running[issue.id].control.status == :working
    assert resumed.running[issue.id].retry_attempt == 2
  end

  # A usage-limit report never replaces an operator, run or label pause, and
  # the rate-limit fallback never resumes such a pause at the reset.
  for {reason, waiting} <- [operator_pause: :paused, global_pause: :run_paused, label_override: :paused] do
    test "a #{reason} survives a usage-limit report and is not resumed at the reset", %{issue: issue} do
      reason = unquote(reason)
      {:ok, reset, 0} = DateTime.from_iso8601(@reset_at)
      pause = %{kind: :usage_limit_exhausted, reason: "error: " <> @banner, reset_hint: "Sep 21st, 2026 6:26 PM", reset_at: @reset_at}

      for status <- [:working, :paused] do
        entry = %{
          issue: issue,
          identifier: issue.identifier,
          pid: self(),
          ref: make_ref(),
          started_at: DateTime.utc_now(),
          paused_reason: reason,
          control: %{status: status, can_interrupt: true}
        }

        state = %Orchestrator.State{running: %{issue.id => entry}, max_concurrent_agents: 6}
        assert {:noreply, paused} = Orchestrator.handle_info({:worker_control_state, issue.id, :paused, pause}, state)
        paused_entry = paused.running[issue.id]
        assert paused_entry.paused_reason == reason
        refute Map.has_key?(paused_entry, :usage_limit_reset_at)
        assert waiting_reason(paused_entry) == unquote(waiting)

        opts = [primary_backend: "codex", current_backend: "codex", marker_label: "agent:rate-limit-fallback", state: %{"backends" => %{}}]

        assert RateLimitFallback.decide(paused_entry, issue, Keyword.merge(opts, fallback_backend: "claude", now: DateTime.add(reset, -1))) == :noop

        after_reset = RateLimitFallback.reconcile(paused, Keyword.merge(opts, fallback_backend: nil, now: DateTime.add(reset, 3600)))
        refute_received {:resume_agent, _request_id}
        assert after_reset.running[issue.id].control.status == :paused
        assert after_reset.running[issue.id].paused_reason == reason
      end
    end
  end

  defp waiting_reason(entry) do
    WaitingReason.for_running(%{
      tracker_state: entry.issue.state,
      pause_reason: Map.get(entry, :paused_reason),
      work_state: entry.control.status,
      open_decision_count: 0,
      stale_for_seconds: 0,
      stall_timeout_seconds: 3600
    })
  end

  defp fake_app_server(trace) do
    frame = fn map -> map |> Jason.encode!() |> String.replace("'", "\\u0027") end
    turn_error = %{"message" => @banner, "codexErrorInfo" => "usageLimitExceeded", "additionalDetails" => nil}

    started = fn turn -> frame.(%{"method" => "turn/started", "params" => %{"threadId" => @thread, "turn" => %{"id" => turn, "status" => "inProgress", "items" => []}}}) end

    failed = fn turn ->
      frame.(%{"method" => "turn/completed", "params" => %{"threadId" => @thread, "turn" => %{"id" => turn, "status" => "failed", "items" => [], "error" => turn_error}}})
    end

    done = fn turn -> frame.(%{"method" => "turn/completed", "params" => %{"threadId" => @thread, "turn" => %{"id" => turn, "status" => "completed", "items" => []}}}) end

    rate_limits = fn used ->
      frame.(%{
        "method" => "account/rateLimits/updated",
        "params" => %{"rateLimits" => %{"primary" => %{"usedPercent" => used, "windowDurationMins" => 10_080, "resetsAt" => @resets_at_epoch}}}
      })
    end

    error = frame.(%{"method" => "error", "params" => %{"error" => turn_error, "willRetry" => false, "threadId" => @thread, "turnId" => @observed_turn}})
    delta = frame.(%{"method" => "item/agentMessage/delta", "params" => %{"threadId" => @thread, "turnId" => "turn-4", "itemId" => "m1", "delta" => @banner}})
    message = frame.(%{"method" => "item/completed", "params" => %{"threadId" => @thread, "turnId" => "turn-4", "item" => %{"type" => "agentMessage", "id" => "m1", "text" => @banner}}})

    tool =
      frame.(%{
        "method" => "item/completed",
        "params" => %{"threadId" => @thread, "turnId" => "turn-4", "item" => %{"type" => "commandExecution", "id" => "c1", "status" => "completed", "aggregatedOutput" => @banner}}
      })

    completed =
      frame.(%{
        "method" => "turn/completed",
        "params" => %{"threadId" => @thread, "turn" => %{"id" => "turn-4", "status" => "completed", "items" => [%{"type" => "agentMessage", "text" => @banner}], "error" => nil}}
      })

    """
    #!/bin/sh
    n=0
    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> "#{trace}"
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"initialized"'*) ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"#{@thread}"}}}' ;;
        *'"method":"turn/start"'*)
          n=$((n + 1))
          rid=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          case "$n" in
            1) turn="#{@observed_turn}" ;;
            *) turn="turn-$n" ;;
          esac
          printf '{"id":%s,"result":{"turn":{"id":"%s","status":"inProgress","items":[]}}}\\n' "$rid" "$turn"
          case "$n" in
            1) printf '%s\\n' '#{started.(@observed_turn)}' '#{rate_limits.(100)}' '#{error}' ;;
            2) printf '%s\\n' '#{failed.(@observed_turn)}' '#{started.("turn-2")}' '#{done.("turn-2")}' ;;
            3) printf '%s\\n' '#{started.("turn-3")}' '#{rate_limits.(99)}' '#{failed.("turn-3")}' ;;
            4) printf '%s\\n' '#{started.("turn-4")}' '#{delta}' '#{message}' '#{tool}' '#{completed}' ;;
            *) printf '%s\\n' '#{started.("turn-5")}' ;;
          esac
          ;;
      esac
    done
    """
  end
end

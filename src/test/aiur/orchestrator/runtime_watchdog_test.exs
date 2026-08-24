defmodule Aiur.Orchestrator.RuntimeWatchdogTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.{PauseResume, Reconciler, RetryEngine, RuntimeWatchdog, State, TokenAccounting}

  test "excludes paused entries from duration overrun" do
    now = DateTime.utc_now()
    entry = %{started_at: DateTime.add(now, -120, :second), control: %{status: :paused}}

    refute RuntimeWatchdog.overrunning_entry?(entry, now, 1)
  end

  test "startup failure is projected as error and releases the slot for retry" do
    now = DateTime.utc_now()

    {failed_entry, _token_delta} =
      TokenAccounting.integrate_codex_update(running_entry(now), %{
        event: :startup_failed,
        timestamp: now,
        reason: :boom
      })

    assert get_in(failed_entry, [:control, :status]) == :error
    refute State.active_running_entry?(failed_entry)

    next_state =
      %State{running: %{"issue-1" => failed_entry}, claimed: MapSet.new(["issue-1"])}
      |> RuntimeWatchdog.apply_runtime_health_check(now)

    refute Map.has_key?(next_state.running, "issue-1")
    refute MapSet.member?(next_state.claimed, "issue-1")
    assert next_state.retry_attempts["issue-1"].error =~ "startup failed"
    cancel_retry(next_state, "issue-1")
  end

  test "startup failure survives the normal worker DOWN as a failure retry" do
    now = DateTime.utc_now()
    ref = make_ref()
    state = %State{running: %{"issue-1" => %{running_entry(now) | ref: ref}}}

    assert {:noreply, failed_state} =
             TokenAccounting.handle_codex_worker_update(state, "issue-1", %{
               event: :startup_failed,
               timestamp: now,
               reason: :boom
             })

    assert {:noreply, next_state} = RetryEngine.handle_agent_down(failed_state, ref, :normal)

    refute Map.has_key?(next_state.running, "issue-1")
    assert next_state.retry_attempts["issue-1"].error == "startup failed: :boom"
    assert next_state.retry_attempts["issue-1"].transient_reason == {:startup_failed, :boom}
    cancel_retry(next_state, "issue-1")
  end

  test "production reconciliation consumes projected startup failures" do
    now = DateTime.utc_now()
    state = %State{running: %{"issue-1" => running_entry(now)}}

    assert {:noreply, failed_state} =
             TokenAccounting.handle_codex_worker_update(state, "issue-1", %{
               event: :startup_failed,
               timestamp: now,
               reason: :boom
             })

    next_state = Reconciler.reconcile_running_lifecycle(failed_state)

    refute Map.has_key?(next_state.running, "issue-1")
    assert next_state.retry_attempts["issue-1"].error =~ "startup failed"
    cancel_retry(next_state, "issue-1")
  end

  test "an interrupted turn without recovery is retried after a bounded grace period" do
    now = DateTime.utc_now()

    {interrupted_entry, _token_delta} =
      TokenAccounting.integrate_codex_update(running_entry(now), interrupted_update(now))

    state = %State{running: %{"issue-1" => interrupted_entry}}

    assert %State{running: %{"issue-1" => _entry}} =
             RuntimeWatchdog.apply_runtime_health_check(state, DateTime.add(now, 999, :millisecond), interrupted_grace_ms: 1_000)

    next_state =
      RuntimeWatchdog.apply_runtime_health_check(state, DateTime.add(now, 1_001, :millisecond), interrupted_grace_ms: 1_000)

    refute Map.has_key?(next_state.running, "issue-1")
    assert next_state.retry_attempts["issue-1"].error =~ "interrupted turn"
    cancel_retry(next_state, "issue-1")
  end

  test "a new turn clears interrupted-turn evidence" do
    now = DateTime.utc_now()

    {interrupted_entry, _token_delta} =
      TokenAccounting.integrate_codex_update(running_entry(now), interrupted_update(now))

    {recovered_entry, _token_delta} =
      TokenAccounting.integrate_codex_update(interrupted_entry, %{
        event: :notification,
        timestamp: DateTime.add(now, 1, :second),
        payload: %{"method" => "turn/started"}
      })

    refute Map.has_key?(recovered_entry, :interrupted_turn_observed_at)

    next_state =
      %State{running: %{"issue-1" => recovered_entry}}
      |> RuntimeWatchdog.apply_runtime_health_check(DateTime.add(now, 31, :second))

    assert Map.has_key?(next_state.running, "issue-1")
    assert next_state.retry_attempts == %{}
  end

  test "a new session clears interrupted-turn evidence" do
    now = DateTime.utc_now()

    {interrupted_entry, _token_delta} =
      TokenAccounting.integrate_codex_update(running_entry(now), interrupted_update(now))

    {recovered_entry, _token_delta} =
      TokenAccounting.integrate_codex_update(interrupted_entry, %{
        event: :session_started,
        timestamp: DateTime.add(now, 1, :second),
        session_id: "session-2"
      })

    refute Map.has_key?(recovered_entry, :interrupted_turn_observed_at)

    next_state =
      %State{running: %{"issue-1" => recovered_entry}}
      |> RuntimeWatchdog.apply_runtime_health_check(DateTime.add(now, 31, :second))

    assert Map.has_key?(next_state.running, "issue-1")
    assert next_state.retry_attempts == %{}
  end

  test "a confirmed pause clears interrupted-turn evidence" do
    now = DateTime.utc_now()

    {interrupted_entry, _token_delta} =
      TokenAccounting.integrate_codex_update(running_entry(now), interrupted_update(now))

    state = %State{running: %{"issue-1" => interrupted_entry}}

    assert {:noreply, paused_state} =
             PauseResume.handle_worker_control_state(state, "issue-1", :paused, %{})

    paused_entry = paused_state.running["issue-1"]
    assert get_in(paused_entry, [:control, :status]) == :paused
    refute Map.has_key?(paused_entry, :interrupted_turn_observed_at)

    next_state =
      RuntimeWatchdog.apply_runtime_health_check(
        paused_state,
        DateTime.add(now, 31, :second)
      )

    assert Map.has_key?(next_state.running, "issue-1")
    assert next_state.retry_attempts == %{}
  end

  test "two frozen working-runtime samples alert and release the slot" do
    now = DateTime.utc_now()
    frozen_entry = %{running_entry(now) | paused_at: DateTime.add(now, -30, :second)}

    first_state =
      %State{running: %{"issue-1" => frozen_entry}}
      |> RuntimeWatchdog.apply_runtime_health_check(now, emit_alert: alert_recorder(self()))

    assert Map.has_key?(first_state.running, "issue-1")
    refute_received {:watchdog_alert, _, _, _}

    next_state =
      RuntimeWatchdog.apply_runtime_health_check(first_state, DateTime.add(now, 2, :second), emit_alert: alert_recorder(self()))

    assert_received {:watchdog_alert, "ticket.repo#1.agent.frozen-runtime", message, opts}
    assert message =~ "runtime remained frozen"
    assert opts[:needs_attention] == true
    refute Map.has_key?(next_state.running, "issue-1")
    assert next_state.retry_attempts["issue-1"].error =~ "runtime remained frozen"
    cancel_retry(next_state, "issue-1")
  end

  test "advancing working runtime does not alert or restart" do
    now = DateTime.utc_now()

    first_state =
      %State{running: %{"issue-1" => running_entry(now)}}
      |> RuntimeWatchdog.apply_runtime_health_check(now, emit_alert: alert_recorder(self()))

    next_state =
      RuntimeWatchdog.apply_runtime_health_check(first_state, DateTime.add(now, 2, :second), emit_alert: alert_recorder(self()))

    assert Map.has_key?(next_state.running, "issue-1")
    assert next_state.retry_attempts == %{}
    refute_received {:watchdog_alert, _, _, _}
  end

  defp running_entry(now) do
    %{
      pid: nil,
      ref: nil,
      identifier: "repo#1",
      issue: %Issue{id: "issue-1", identifier: "repo#1", state: "in-progress"},
      started_at: DateTime.add(now, -60, :second),
      paused_at: nil,
      control: %{status: :working},
      retry_attempt: 0,
      workspace_path: nil,
      worker_host: nil,
      session_id: "session-1"
    }
  end

  defp interrupted_update(now) do
    %{
      event: :notification,
      timestamp: now,
      payload: %{
        "method" => "turn/completed",
        "params" => %{"turn" => %{"status" => "interrupted"}}
      }
    }
  end

  defp alert_recorder(test_pid) do
    fn name, message, opts ->
      send(test_pid, {:watchdog_alert, name, message, opts})
      :ok
    end
  end

  defp cancel_retry(state, issue_id) do
    if timer_ref = get_in(state.retry_attempts, [issue_id, :timer_ref]) do
      Process.cancel_timer(timer_ref)
    end
  end
end

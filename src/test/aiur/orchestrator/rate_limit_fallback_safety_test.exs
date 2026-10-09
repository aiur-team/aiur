defmodule Aiur.Orchestrator.RateLimitFallbackSafetyTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.Issue
  alias Aiur.Orchestrator.{AgentTeardown, RateLimitFallback, RetryEngine, State, TokenAccounting, TrackerTasks}

  test "completion accounting accepts an entry without started_at" do
    result = TokenAccounting.record_session_completion_totals(%State{}, %{identifier: "repo#legacy"})
    assert result.agent_totals.seconds_running == 0
  end

  test "parked fallback survives retry-engine completion and totals are recorded once" do
    state = state(["1"])
    original = state.running["1"].started_at
    parked = RateLimitFallback.reconcile(state, opts())
    assert parked.running["1"].started_at == original
    assert parked.running["1"].completion_totals_recorded == false
    {:noreply, completed} = RetryEngine.handle_agent_down(parked, nil, :normal)
    assert completed.agent_totals.seconds_running in 119..122
    assert completed.running["1"].completion_totals_recorded
    {:noreply, again} = RetryEngine.handle_agent_down(completed, nil, :normal)
    assert again.agent_totals == completed.agent_totals
  end

  test "account handoff parks a complete entry that agent teardown can remove" do
    state = state(["1"])
    entry = state.running["1"] |> Map.delete(:started_at) |> Map.put(:usage_limit_session, %{backend: "claude-repl", account_name: "default", session_id: "s1", cwd: "/repo"})
    state = %{state | running: %{"1" => entry}}

    parked =
      RateLimitFallback.reconcile(
        state,
        opts(
          account_config: %{accounts: %{"claude" => ["default", "work"]}, account_selection: "priority"},
          account_list_fun: fn _ -> [%{name: "default"}, %{name: "work"}] end,
          account_usage_fetcher: fn _ -> %{"seven_day" => 0, "five_hour" => 0} end,
          move_session_fun: fn _, _, _, _, _, _ -> :ok end,
          handoff_event_fun: fn _, _, _, _ -> :ok end,
          dispatch_fun: fn current, _, _, _, _ -> current end
        )
      )

    assert %DateTime{} = parked.running["1"].started_at
    assert parked.running["1"].completion_totals_recorded == false
    removed = AgentTeardown.terminate_running_issue(parked, "1", false)
    refute Map.has_key?(removed.running, "1")
    assert removed.agent_totals.seconds_running in 0..2
  end

  test "a failing write does not consume the only transition slot" do
    parent = self()

    options =
      opts(
        add_label_fun: fn id, _ -> if id == "repo#1", do: {:error, :denied}, else: :ok end,
        dispatch_fun: fn current, issue, _, _ ->
          send(parent, {:dispatched, issue.id})
          current
        end
      )

    result = RateLimitFallback.reconcile(state(["1", "2", "3"]), options)
    assert_received {:dispatched, "2"}
    refute_received {:dispatched, "3"}
    assert result.fallback_backoff["1"] == {1, 100}
    assert result.running["1"].issue.labels == []
  end

  test "backoff doubles, caps at ten minutes, alerts once, and success resets failures" do
    parent = self()

    options =
      opts(
        add_label_fun: fn id, _ ->
          send(parent, {:write, id})
          {:error, :denied}
        end,
        emit_alert_fun: fn topic, fields ->
          send(parent, {:alert, topic, fields})
          :ok
        end
      )

    failed = RateLimitFallback.reconcile(state(["1"]), options)
    assert_received {:write, "repo#1"}
    assert failed.fallback_backoff["1"] == {1, 100}
    assert RateLimitFallback.reconcile(failed, Keyword.put(options, :now_ms, 99)) == failed
    refute_received {:write, _}
    twice = RateLimitFallback.reconcile(failed, Keyword.put(options, :now_ms, 100))
    assert_received {:write, "repo#1"}
    assert twice.fallback_backoff["1"] == {2, 300}
    refute_received {:alert, _, _}
    third = RateLimitFallback.reconcile(twice, Keyword.put(options, :now_ms, 300))
    assert third.fallback_backoff["1"] == {3, 700}
    assert_received {:alert, "ticket.repo#1.agent.rate_limit_fallback_write_failed", fields}
    assert fields[:issue].identifier == "repo#1"
    assert fields[:reason] =~ ":denied"
    assert fields[:needs_attention]

    capped =
      Enum.reduce(4..15, third, fn _, current ->
        {attempts, deadline} = current.fallback_backoff["1"]
        next = RateLimitFallback.reconcile(current, Keyword.put(options, :now_ms, deadline))
        assert {next_attempts, next_deadline} = next.fallback_backoff["1"]
        assert next_attempts == attempts + 1
        assert next_deadline - deadline == min(100 * Integer.pow(2, attempts), 600_000)
        next
      end)

    refute_received {:alert, _, _}
    {_, deadline} = capped.fallback_backoff["1"]
    succeeded = RateLimitFallback.reconcile(capped, opts(now_ms: deadline))
    assert succeeded.fallback_backoff == %{}
    assert "agent:rate-limit-fallback" in succeeded.running["1"].issue.labels
  end

  test "backoff is pruned when a ticket leaves running" do
    failed = RateLimitFallback.reconcile(state(["1"]), opts(add_label_fun: fn _, _ -> {:error, :denied} end))
    result = RateLimitFallback.reconcile(%{failed | running: %{}}, opts())
    assert result.fallback_backoff == %{}
  end

  test "pending async write cannot starve another ticket and unknown completion backs off" do
    parent = self()
    owner = {__MODULE__, make_ref()}
    :yes = :global.register_name(owner, parent)
    on_exit(fn -> :global.unregister_name(owner) end)
    initial = %{state(["1", "2"]) | snapshot_key: {:global, owner}}

    options =
      opts(
        add_label_fun: fn id, _ ->
          if id == "repo#1" do
            send(parent, {:writer, self()})

            receive do
              :release -> {:error, :timeout}
            end
          else
            :ok
          end
        end
      )

    pending = RateLimitFallback.reconcile(initial, options)
    receive_barrier({:writer, worker})
    later = RateLimitFallback.reconcile(pending, options)
    assert map_size(later.tracker_tasks) == 2
    assert length(Enum.filter(later.tracker_tasks, fn {_, job} -> job.key == {:fallback_labels, "1"} end)) == 1
    send(worker, :release)
    receive_barrier({ref, result})
    {:handled, applied} = TrackerTasks.result(later, ref, result)
    # The two independent tasks may finish in either order.
    receive_barrier({other_ref, other_result})
    {:handled, applied} = TrackerTasks.result(applied, other_ref, other_result)
    assert applied.fallback_backoff["1"] == {1, 100}
    assert applied.running["1"].issue.labels == []
    assert "model:claude" in applied.running["2"].issue.labels
    TrackerTasks.stop(applied)
  end

  defp state(ids) do
    running =
      Map.new(ids, fn id ->
        issue = %Issue{id: id, identifier: "repo##{id}", labels: []}
        {id, %{issue: issue, identifier: issue.identifier, control: %{status: :paused}, paused_reason: :usage_limit_exhausted, started_at: DateTime.add(DateTime.utc_now(), -120), pid: nil, ref: nil}}
      end)

    %State{running: running, poll_interval_ms: 100}
  end

  defp opts(overrides \\ []) do
    Keyword.merge(
      [
        primary_backend: "codex",
        fallback_backend: "claude",
        marker_label: "agent:rate-limit-fallback",
        current_backend: "codex",
        state: %{"backends" => %{}},
        now_ms: 0,
        backend_ready_fun: fn _, _ -> true end,
        dispatch_ready_fun: fn _, _, _ -> :ok end,
        add_label_fun: fn _, _ -> :ok end,
        remove_label_fun: fn _, _ -> :ok end,
        teardown_fun: fn current, _, _ -> current end,
        dispatch_fun: fn current, _, _, _ -> current end,
        schedule_retry_fun: fn current, _, _, _ -> current end
      ],
      overrides
    )
  end
end

defmodule Aiur.Orchestrator.Dispatcher.EntryTest do
  use Aiur.DispatcherTestSupport

  test "successful validation clears a previous decline in both execution modes" do
    parent = self()
    candidate = %{issue("decline-cleared") | selected_backend: "codex"}
    :ok = AgentPubSub.subscribe_agent(candidate.identifier)
    resolution = "ticket.#{candidate.id}.agent.attention.dispatch-declined.resolved"

    for owner <- [nil, self()] do
      state = %State{snapshot_key: owner, max_concurrent_agents: 4, effective_concurrent_agents: 4}

      declined =
        Dispatcher.dispatch_issue(state, candidate, nil, nil,
          issue_fetcher: fn _ -> {:error, :controlled_failure} end,
          blocked_by_hydrator: fn value -> {:ok, value} end
        )

      declined = apply_test_dispatch_result(declined, owner)
      assert declined.dispatch_declines[candidate.id] == :tracker_revalidation_failed
      attention = String.replace_suffix(resolution, ".resolved", "")
      receive_barrier({:alert, %{name: ^attention, needs_attention: true}})

      pending =
        Dispatcher.dispatch_issue(declined, candidate, nil, nil,
          issue_fetcher: fn _ -> {:ok, [candidate]} end,
          blocked_by_hydrator: fn value -> {:ok, value} end,
          runner: fn dispatched, _, _ ->
            send(parent, {:started, dispatched.id})
            :ok
          end
        )

      applied = apply_test_dispatch_result(pending, owner)

      receive_barrier({:started, id})
      assert id == candidate.id
      assert Map.has_key?(applied.running, candidate.id)
      refute Map.has_key?(applied.dispatch_declines, candidate.id)
      receive_barrier({:alert, %{name: ^resolution, needs_attention: false}})
    end
  end

  test "a held candidate validation chain prevents another poll cycle" do
    parent = self()
    candidate = issue("held-chain")

    pending =
      Dispatcher.choose_issues(%State{snapshot_key: self(), effective_concurrent_agents: 4}, [candidate],
        issue_fetcher: fn _ ->
          send(parent, {:held_dispatch, self()})
          receive do: (:release -> {:error, :controlled_failure})
        end,
        blocked_by_hydrator: fn value -> {:ok, value} end
      )

    receive_barrier({:held_dispatch, worker})
    assert {:noreply, waiting} = Dispatcher.run_poll_cycle(pending)
    assert waiting.tracker_tasks == pending.tracker_tasks
    refute TrackerTasks.running?(waiting, :dispatch_poll)
    assert is_reference(waiting.tick_timer_ref)
    Process.cancel_timer(waiting.tick_timer_ref)
    send(worker, :release)
    receive_barrier({ref, result})
    assert {:handled, final} = TrackerTasks.result(waiting, ref, result)
    assert final.tracker_tasks == %{}
  end

  test "async candidate validation keeps dispatch priority order across slow reads" do
    owner = self()
    high = %Aiur.Issue{id: "async-high", identifier: "ASYNC-HIGH", title: "high", state: "Todo", priority: 1}
    low = %Aiur.Issue{id: "async-low", identifier: "ASYNC-LOW", title: "low", state: "Todo", priority: 3}

    pending =
      Dispatcher.choose_issues(%State{snapshot_key: self(), effective_concurrent_agents: 4}, [low, high],
        issue_fetcher: fn [id] ->
          send(owner, {:validation_started, id, self()})
          receive do: (:release -> {:error, :controlled_failure})
        end,
        blocked_by_hydrator: fn value -> {:ok, value} end
      )

    receive_barrier({:validation_started, "async-high", high_worker})
    assert TrackerTasks.running?(pending, {:dispatch, high.id})
    refute TrackerTasks.running?(pending, {:dispatch, low.id})
    send(high_worker, :release)
    receive_barrier({ref, result})
    {:handled, next} = TrackerTasks.result(pending, ref, result)
    receive_barrier({:validation_started, "async-low", low_worker})
    send(low_worker, :release)
    receive_barrier({ref, result})
    {:handled, next} = TrackerTasks.result(next, ref, result)
    assert next.tracker_tasks == %{}
  end

  test "a delayed dispatch revalidation respects a newly applied global pause" do
    owner = self()
    issue = %Aiur.Issue{id: "async-pause", identifier: "ASYNC-PAUSE", title: "pause", state: "Todo"}

    pending =
      Dispatcher.dispatch_issue(%State{snapshot_key: self(), effective_concurrent_agents: 4}, issue, nil, nil,
        issue_fetcher: fn _ ->
          send(owner, {:validation_started, self()})
          receive do: (:release -> {:ok, [issue]})
        end,
        blocked_by_hydrator: fn value -> {:ok, value} end,
        runner: fn _, _, _ -> flunk("dispatch started during global pause") end
      )

    receive_barrier({:validation_started, worker})
    send(worker, :release)
    receive_barrier({ref, result})
    {:handled, next} = TrackerTasks.result(%{pending | globally_paused: true}, ref, result)
    assert next.running == %{}
    assert next.globally_paused
    assert next.tracker_tasks == %{}
  end

  test "failed async dispatch invokes the retry completion after removing its job" do
    owner = self()
    issue = %Aiur.Issue{id: "async-failure", identifier: "ASYNC-FAILURE", title: "failure", state: "Todo"}

    pending =
      Dispatcher.dispatch_issue(%State{snapshot_key: self(), effective_concurrent_agents: 4}, issue, 2, nil,
        issue_fetcher: fn _ -> {:error, :controlled_failure} end,
        blocked_by_hydrator: fn value -> {:ok, value} end,
        dispatch_result_fun: fn current ->
          refute TrackerTasks.issue_pending?(current, issue.id)
          send(owner, :completion_applied)
          %{current | globally_paused: true}
        end
      )

    receive_barrier({ref, result})
    {:handled, next} = TrackerTasks.result(pending, ref, result)
    receive_barrier(:completion_applied)
    assert next.globally_paused
  end

  test "async revalidation records ordinary skips without tracker error attention" do
    issue = %Aiur.Issue{id: "async-missing", identifier: "ASYNC-MISSING", title: "missing", state: "Todo"}

    for {response, reason} <- [{[], :missing_after_revalidation}, {[%{issue | paused: true}], {:stale_after_revalidation, :paused}}] do
      pending =
        Dispatcher.dispatch_issue(%State{snapshot_key: self(), effective_concurrent_agents: 4}, issue, nil, nil,
          issue_fetcher: fn _ -> {:ok, response} end,
          blocked_by_hydrator: fn value -> {:ok, value} end
        )

      receive_barrier({ref, result})
      {:handled, next} = TrackerTasks.result(pending, ref, result)
      assert next.dispatch_declines[issue.id] == reason
      assert next.observed_error_alerts == MapSet.new()
    end
  end

  test "candidate selection emits one reason when a ticket is declined despite free fleet slots" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      max_concurrent_agents: 4,
      max_concurrent_agents_by_state: %{"todo" => 1}
    )

    candidate = issue("declined")
    :ok = AgentPubSub.subscribe_agent(candidate.identifier)

    state = %State{
      max_concurrent_agents: 4,
      effective_concurrent_agents: 4,
      running: %{
        "active" => %{issue: issue("active"), identifier: "repo#active", control: %{status: :working}}
      }
    }

    first = Dispatcher.choose_issues(state, [candidate])

    assert first.dispatch_declines[candidate.id] == :state_capacity

    assert_receive {:alert,
                    %{
                      name: "dispatch.candidate_declined",
                      reason: reason,
                      needs_attention: false
                    }},
                   2_000

    assert reason =~ "state_capacity"

    _same = Dispatcher.choose_issues(first, [candidate])
    refute_receive {:alert, %{name: "dispatch.candidate_declined"}}, 100
  end

  test "a selected ticket emits the revalidation reason when dispatch aborts before provisioning" do
    candidate = issue("refresh-failed")
    :ok = AgentPubSub.subscribe_agent(candidate.identifier)

    declined =
      Dispatcher.dispatch_issue(%State{}, candidate, nil, nil,
        issue_fetcher: fn [candidate_id] ->
          assert candidate_id == candidate.id
          {:error, :tracker_unavailable}
        end
      )

    assert declined.dispatch_declines[candidate.id] == :tracker_revalidation_failed

    assert_receive {:alert,
                    %{
                      name: name,
                      reason: reason,
                      needs_attention: true
                    }},
                   2_000

    assert name == "ticket.#{candidate.id}.agent.attention.dispatch-declined"
    assert reason =~ "tracker_revalidation_failed"
  end

  test "a ready Codex ticket reaches the dispatcher after a stale limit refresh" do
    restore_workflow_file_after_test()
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "memory", max_concurrent_agents: 4)
    ledger = ModelAvailability.path()
    old_ledger = if File.exists?(ledger), do: File.read!(ledger), else: nil
    on_exit(fn -> if is_binary(old_ledger), do: File.write!(ledger, old_ledger), else: File.rm(ledger) end)

    now = DateTime.utc_now()
    stale_at = DateTime.add(now, -301, :second)
    reset_at = DateTime.add(now, 3_600, :second) |> DateTime.to_iso8601()
    assert :ok = ModelAvailability.observe("codex", %{hourly: %{usedPercent: 100, windowDurationMins: 60, resetsAt: reset_at}}, now: stale_at)

    assert :ok =
             Aiur.CodexProber.probe_sync("codex", now,
               fetch_limits_fun: fn ->
                 {:ok, %{"rateLimits" => %{"primary" => %{"usedPercent" => 4, "windowDurationMins" => 60}}}}
               end
             )

    candidate = issue("codex-refresh-ready")
    Application.put_env(:aiur, :memory_tracker_issues, [candidate])
    on_exit(fn -> Application.delete_env(:aiur, :memory_tracker_issues) end)
    parent = self()

    runner = fn dispatched, _recipient, _opts ->
      send(parent, {:ready_ticket_started, dispatched.id})
      Process.sleep(:infinity)
    end

    result = Dispatcher.choose_issues(%State{max_concurrent_agents: 4, effective_concurrent_agents: 4}, [candidate], runner: runner)

    assert_receive {:ready_ticket_started, id}, 2_000
    assert id == candidate.id
    assert Map.has_key?(result.running, candidate.id)
    Process.exit(result.running[candidate.id].pid, :kill)
  end

  test "a repeated post-selection decline is emitted once across polling cycles" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "memory", max_concurrent_agents: 4)
    Application.put_env(:aiur, :memory_tracker_issues, [])
    on_exit(fn -> Application.delete_env(:aiur, :memory_tracker_issues) end)

    candidate = issue("missing-after-selection")
    :ok = AgentPubSub.subscribe_agent(candidate.identifier)

    first = Dispatcher.choose_issues(%State{effective_concurrent_agents: 4}, [candidate])
    assert first.dispatch_declines[candidate.id] == :missing_after_revalidation
    assert_receive {:alert, %{name: "dispatch.candidate_declined"}}, 2_000

    _second = Dispatcher.choose_issues(first, [candidate])
    refute_receive {:alert, %{name: "dispatch.candidate_declined"}}, 100
  end

  # A candidate whose dispatch authorization could not be read (`:deferred` —
  # a local GitHub budget hold, a rate limit, a timeline transport fault) used
  # to be skipped in complete silence: no alert, no decline record, and the
  # catch-all `maybe_emit_dispatch_decline/3` clause cleared any earlier one.
  # With free slots, the operator saw the ticket vanish rather than wait.
  test "records a decline when authorization is deferred and slots are free" do
    candidate = %{issue("auth-deferred") | dispatch_authorized?: false, dispatch_authorization: :deferred}

    state = Dispatcher.choose_issues(%State{max_concurrent_agents: 4, effective_concurrent_agents: 4}, [candidate])

    assert state.dispatch_declines[candidate.id] == :unauthorized
    refute Map.has_key?(state.running, candidate.id)
  end

  test "clearing an attention decline emits its matching resolution" do
    candidate = issue("orphaned-claim")
    :ok = AgentPubSub.subscribe_agent(candidate.identifier)

    claimed = %State{effective_concurrent_agents: 4, claimed: MapSet.new([candidate.id])}
    declined = Dispatcher.choose_issues(claimed, [candidate])

    assert_receive {:alert,
                    %{
                      name: "ticket.orphaned-claim.agent.attention.dispatch-declined",
                      needs_attention: true
                    }},
                   2_000

    recovered = %{declined | claimed: MapSet.new()}
    _cleared = Dispatcher.choose_issues(recovered, [%{candidate | state: "done"}])

    assert_receive {:alert,
                    %{
                      name: "ticket.orphaned-claim.agent.attention.dispatch-declined.resolved",
                      needs_attention: false
                    }},
                   2_000
  end

  test "an orphaned claim is released and redispatched" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_concurrent_agents: 4
    )

    candidate = issue("orphaned-claim-recovery")
    Application.put_env(:aiur, :memory_tracker_issues, [candidate])
    on_exit(fn -> Application.delete_env(:aiur, :memory_tracker_issues) end)

    parent = self()

    runner = fn issue, _recipient, _opts ->
      send(parent, {:orphan_recovered, issue.id})
      Process.sleep(:infinity)
    end

    claimed = %State{effective_concurrent_agents: 4, claimed: MapSet.new([candidate.id])}
    recovered = Dispatcher.choose_issues(claimed, [candidate], runner: runner)

    assert_receive {:orphan_recovered, "orphaned-claim-recovery"}, 2_000
    assert Map.has_key?(recovered.running, candidate.id)
    assert MapSet.member?(recovered.claimed, candidate.id)
    Process.exit(recovered.running[candidate.id].pid, :kill)
  end

  test "the first candidate poll holds orphaned claims during recovery grace" do
    restore_workflow_file_after_test()
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "memory")

    candidate = %{issue("startup-orphan") | state: "in-progress"}
    candidate_identifier = candidate.identifier
    previous_issues = Application.get_env(:aiur, :memory_tracker_issues)
    previous_recipient = Application.get_env(:aiur, :memory_tracker_recipient)

    Application.put_env(:aiur, :memory_tracker_issues, [candidate])
    Application.put_env(:aiur, :memory_tracker_recipient, self())

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_issues)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end)

    next =
      Dispatcher.maybe_dispatch(%State{
        initial_dispatch_cycle: true,
        max_concurrent_agents: 1
      })

    refute_received {:memory_tracker_state_update, ^candidate_identifier, _target}
    refute next.startup_claim_reconciliation_complete?
    assert next.last_polled_issues[candidate.id].state == "in-progress"
    refute next.initial_dispatch_cycle
  end

  test "a failed candidate poll does not run startup claim reconciliation" do
    restore_workflow_file_after_test()

    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_active_states: ["Todo", "In Progress", "Rework", "Merging"]
    )

    previous_client = Application.get_env(:aiur, :linear_client_module)
    Application.put_env(:aiur, :linear_client_module, CandidateFetchFailureLinearClient)
    on_exit(fn -> restore_app_env(:linear_client_module, previous_client) end)

    state = %State{
      initial_dispatch_cycle: true,
      last_polled_issues: %{
        "startup-orphan" => %{issue("startup-orphan") | state: "In Progress"}
      }
    }

    next = Dispatcher.maybe_dispatch(state)

    refute next.startup_claim_reconciliation_complete?
    assert next.last_polled_issues == state.last_polled_issues
    assert next.initial_dispatch_cycle
  end

  test "a successful candidate poll starts the DecisionStore outage alert dwell" do
    store = Process.whereis(Aiur.DecisionStore)
    original_health = :sys.get_state(store).health
    :sys.replace_state(store, &%{&1 | health: {:unavailable, :test}})
    on_exit(fn -> :sys.replace_state(store, &%{&1 | health: original_health}) end)

    candidate = issue("decision-store-outage")

    state = %State{
      max_concurrent_agents: 4,
      effective_concurrent_agents: 4,
      blocked_ticket_ids: :unavailable
    }

    next =
      Dispatcher.dispatch_candidate_poll(state,
        fetch_candidate_issues_fun: fn current -> {:ok, [candidate], current} end,
        stranded_reconciliation_fun: fn current, _issues -> current end
      )

    assert is_integer(next.decision_store_unavailable_since_ms)
    refute next.decision_store_unavailable_alert_active
    assert next.dispatch_declines[candidate.id] == :blocked_on_decision
  end
end

Code.require_file("fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.LifetimeDispatchBudget.ResetAndAdmissionTest do
  use Aiur.LifetimeDispatchBudgetCase, async: false
  import Aiur.LifetimeDispatchBudgetCase, only: [thrash_budget: 1, with_thrash_budget: 2]

  alias Aiur.AgentPubSub
  alias Aiur.DispatchBudgetStore
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.PauseResume

  @issue_id "issue-lifetime"
  @window_ms 60 * 1_000

  @enabled """
  tracker:
    kind: memory
    active_states:
      - todo
      - in-progress
      - rework
  agent:
    kind: codex
    max_dispatches_per_ticket: 10
  """

  @tag config: @enabled
  test "resume against a latched idle ticket reports the latch instead of no-opping" do
    issue = %Issue{
      id: @issue_id,
      identifier: "repo#lifetime",
      title: "Latched",
      state: "in-progress",
      paused: true,
      labels: ["agent:in-progress", "agent:paused"]
    }

    # The queued resume path re-reads the tracker before it judges
    # dispatchability, so the authoritative read has to see this issue.
    previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)
    Application.put_env(:aiur, :memory_tracker_issues, [issue])

    on_exit(fn ->
      if is_nil(previous_memory_issues) do
        Application.delete_env(:aiur, :memory_tracker_issues)
      else
        Application.put_env(:aiur, :memory_tracker_issues, previous_memory_issues)
      end
    end)

    :ok = DispatchBudgetStore.put_lifetime(@issue_id, 10)

    state =
      %Orchestrator.State{last_polled_issues: %{@issue_id => issue}}
      |> with_thrash_budget(%{@issue_id => %{window_start_ms: 0, count: 1, lifetime: 10}})

    # `resume_issue/2` routes a no-running-agent resume to the queued path,
    # which must name the latch (not a generic `:dispatch_failed`).
    assert {{:error, :lifetime_dispatch_latch}, next_state} =
             PauseResume.resume_issue(state, "repo#lifetime")

    assert next_state.last_polled_issues[@issue_id].paused
    assert "agent:paused" in next_state.last_polled_issues[@issue_id].labels
  end

  @tag config: @enabled
  test "the reset control call clears the in-memory and durable latch copies" do
    issue = %Issue{id: @issue_id, identifier: "repo#lifetime", title: "Latched", state: "in-progress"}
    :ok = DispatchBudgetStore.put_lifetime(@issue_id, 10)

    state =
      %Orchestrator.State{last_polled_issues: %{@issue_id => issue}}
      |> with_thrash_budget(%{@issue_id => %{window_start_ms: 0, count: 1, lifetime: 10}})

    assert {:reply, {:ok, :reset}, reset_state} =
             reset_control_call(state, "repo#lifetime")

    assert :none = Dispatcher.dispatch_latch_status(reset_state, @issue_id)
    assert {:ok, 0} = DispatchBudgetStore.lifetime(@issue_id)
  end

  @tag config: @enabled
  test "reset resolves a latched ticket pruned from the polled set via a tracker fetch" do
    # #2435: a latched ticket left in `agent:error` (a non-active state) is
    # dropped from `last_polled_issues` by the disappearing-issue
    # reconciliation, so the in-memory lookup alone resolves it as
    # `:unknown_issue` and `reset-budget` reports success while the durable
    # latch stays in place. the reset control call must fall back to a
    # direct tracker fetch so the ticket is actually cleared and restored to a
    # dispatchable state.
    issue = %Issue{id: "pruned-lifetime", identifier: "repo#pruned-lifetime", title: "Latched", state: "error"}
    previous_issues = Application.get_env(:aiur, :memory_tracker_issues)
    Application.put_env(:aiur, :memory_tracker_issues, [issue])

    on_exit(fn ->
      if is_nil(previous_issues) do
        Application.delete_env(:aiur, :memory_tracker_issues)
      else
        Application.put_env(:aiur, :memory_tracker_issues, previous_issues)
      end
    end)

    :ok = DispatchBudgetStore.put_lifetime("pruned-lifetime", 10)

    # The polled set is empty — the ticket is gone from the poll exactly like
    # an `agent:error` ticket that the active-state candidate poll drops.
    state = %Orchestrator.State{last_polled_issues: %{}}

    assert {:reply, {:ok, :reset}, reset_state} =
             reset_control_call(state, "pruned-lifetime")

    assert :none = Dispatcher.dispatch_latch_status(reset_state, "pruned-lifetime")
    assert {:ok, 0} = DispatchBudgetStore.lifetime("pruned-lifetime")
    assert %Issue{state: "todo"} = reset_state.last_polled_issues["pruned-lifetime"]
    assert DispatchPolicy.should_dispatch_issue?(reset_state.last_polled_issues["pruned-lifetime"], reset_state)
  end

  @tag config: @enabled
  test "public reset fails loudly, not silently, when the orchestrator mailbox is unresponsive" do
    # #2435: `reset-budget` used to fire-and-forget a cast and report "queued"
    # even when the orchestrator could not act, leaving a latched ticket
    # untouched behind a success message. The public path is now a synchronous
    # call: when the orchestrator cannot answer it returns the timeout so the
    # CLI fails loudly instead of claiming the reset was accepted.
    name = Module.concat(__MODULE__, :SuspendedResetOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name, initial_poll?: false)
    :sys.suspend(pid)

    previous_timeout = Application.get_env(:aiur, :control_api_call_timeout_ms)
    Application.put_env(:aiur, :control_api_call_timeout_ms, 100)

    on_exit(fn ->
      Application.delete_env(:aiur, :control_api_call_timeout_ms)
      if previous_timeout, do: Application.put_env(:aiur, :control_api_call_timeout_ms, previous_timeout)

      if Process.alive?(pid) do
        try do
          :sys.resume(pid)
          Process.exit(pid, :normal)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    assert {:error, :timeout} = PauseResume.reset_dispatch_budget(name, "repo#lifetime")
  end

  @tag config: @enabled
  test "public reset rejects an unavailable orchestrator instead of claiming it queued work" do
    missing = Module.concat(__MODULE__, :MissingResetOrchestrator)

    assert {:error, :unavailable} = PauseResume.reset_dispatch_budget(missing, "repo#lifetime")
  end

  @tag config: @enabled
  test "reset control processing emits completion and failure outcomes" do
    issue = %Issue{id: @issue_id, identifier: "repo#lifetime", title: "Latched", state: "in-progress"}
    :ok = DispatchBudgetStore.put_lifetime(@issue_id, 10)
    :ok = AgentPubSub.subscribe_agent(@issue_id)

    state =
      %Orchestrator.State{last_polled_issues: %{@issue_id => issue}}
      |> with_thrash_budget(%{@issue_id => %{window_start_ms: 0, count: 1, lifetime: 10}})

    {:reply, {:ok, :reset}, reset} = reset_control_call(state, issue.identifier)
    assert :none = Dispatcher.dispatch_latch_status(reset, @issue_id)

    assert_receive {:alert,
                    %{
                      name: "ticket.issue-lifetime.agent.attention.dispatch-budget-reset.resolved",
                      needs_attention: false
                    }},
                   2_000

    :ok = AgentPubSub.subscribe_agent("missing")
    {:reply, {:error, :unknown_issue}, _unchanged} = reset_control_call(reset, "missing")

    assert_receive {:alert,
                    %{
                      name: "ticket.missing.agent.attention.dispatch-budget-reset",
                      needs_attention: true
                    }},
                   2_000
  end

  @tag config: @enabled
  test "a durable reset failure is surfaced instead of reporting false success" do
    # #1453 review P2b: `reset_lifetime_budget/2` used to discard the durable
    # store's result, so `reset-budget` reported success while the latch would
    # survive a restart. A failed durable write must surface as an error.
    issue = %Issue{id: @issue_id, identifier: "repo#lifetime", title: "Latched", state: "in-progress"}
    :ok = DispatchBudgetStore.put_lifetime(@issue_id, 10)

    state =
      %Orchestrator.State{last_polled_issues: %{@issue_id => issue}}
      |> with_thrash_budget(%{@issue_id => %{window_start_ms: 0, count: 1, lifetime: 10}})

    # Point the durable store at an unreadable path so the reset write fails.
    unreadable_path = Path.join(Path.dirname(DispatchBudgetStore.path_for()), "is-a-directory")
    File.mkdir_p!(unreadable_path)
    Application.put_env(:aiur, :dispatch_budget_store_path, unreadable_path)

    assert {:reply, {:error, {:budget_reset_failed, _reason}}, reset_state} =
             reset_control_call(state, "repo#lifetime")

    # The in-memory latch was cleared this generation, but the failure is
    # reported so the operator knows it will re-latch on restart.
    assert :none = Dispatcher.dispatch_latch_status(reset_state, @issue_id)
  end

  @tag config: @enabled
  test "reset-budget restores a latched agent:error ticket to todo, never rework" do
    # #1453 review P2c: a latched ticket is durably moved to `agent:error`
    # (not an active state), so clearing the budget alone left it
    # undispatchable. The reset control call must also restore it to a
    # dispatchable state so the reset actually returns the ticket to the board.
    #
    # #2075 criterion 3: the restore writes `todo`, never `rework` — a lifetime
    # dispatch latch is an exhaustion of retry budget, not a reviewer's
    # rejection, so `rework` would assert a verdict that never happened and
    # strand a no-PR ticket in a state nothing selects. The precondition this
    # writer requires is "budget restore, no review verdict", which `todo`
    # names.
    issue = %Issue{id: @issue_id, identifier: "repo#lifetime", title: "Latched", state: "error"}
    :ok = DispatchBudgetStore.put_lifetime(@issue_id, 10)

    state =
      %Orchestrator.State{last_polled_issues: %{@issue_id => issue}}
      |> with_thrash_budget(%{@issue_id => %{window_start_ms: 0, count: 1, lifetime: 10}})

    assert {:reply, {:ok, :reset}, reset_state} =
             reset_control_call(state, "repo#lifetime")

    assert :none = Dispatcher.dispatch_latch_status(reset_state, @issue_id)
    assert %Issue{state: "todo"} = reset_state.last_polled_issues[@issue_id]
    assert DispatchPolicy.should_dispatch_issue?(reset_state.last_polled_issues[@issue_id], reset_state)
  end

  @tag config: @enabled
  test "rework dispatchability is gated by the lifetime latch, not the rework state" do
    # #1453 review P2f: the original acceptance test only asserted the
    # (unchanged) `should_dispatch_issue?` predicate, which passed even before
    # the fix — rework was already an active state. This proves the latch is
    # the dispatch gate: the SAME rework ticket dispatches when not latched,
    # is refused by the dispatch gate when latched, and dispatches again after
    # the supported reset.
    issue = %Issue{id: @issue_id, identifier: "repo#lifetime", title: "Rework", state: "rework"}
    state = %Orchestrator.State{last_polled_issues: %{@issue_id => issue}}

    # Not latched: a full dispatch candidate with free capacity.
    assert DispatchPolicy.should_dispatch_issue?(issue, state)

    # Latched at the cap: the dispatch gate refuses even though the rework
    # ticket is otherwise a valid candidate — the latch is the gate.
    :ok = DispatchBudgetStore.put_lifetime(@issue_id, 10)

    latched =
      state
      |> with_thrash_budget(%{@issue_id => %{window_start_ms: 0, count: 1, lifetime: 10}})

    assert {:lifetime, 10, 10} = Dispatcher.dispatch_latch_status(latched, @issue_id)
    assert {:trip, _} = Dispatcher.check_thrash_budget(latched, @issue_id, @window_ms + 1)

    # After the supported reset, the same rework ticket is dispatchable again.
    {reset_state, :ok} = Dispatcher.reset_lifetime_budget(latched, @issue_id)
    assert :none = Dispatcher.dispatch_latch_status(reset_state, @issue_id)
    assert DispatchPolicy.should_dispatch_issue?(issue, reset_state)
  end

  @tag config: @enabled
  test "redispatch preflight rejects the next dispatch when the lifetime latch is exhausted" do
    issue = %Issue{id: @issue_id, identifier: "repo#lifetime", selected_backend: "claude"}

    state =
      with_thrash_budget(%Orchestrator.State{}, %{
        @issue_id => %{window_start_ms: 0, count: 1, lifetime: 10}
      })

    assert {:error, :thrash_circuit_open} =
             Dispatcher.redispatch_ready?(state, issue, nil, now_ms: @window_ms + 1)

    assert get_in(thrash_budget(state), [@issue_id, :lifetime]) == 10
  end

  @tag config: @enabled
  test "stateful redispatch admission returns the committed lifetime trip" do
    issue = %Issue{id: @issue_id, identifier: "repo#lifetime", selected_backend: "claude"}

    state =
      with_thrash_budget(%Orchestrator.State{}, %{
        @issue_id => %{window_start_ms: 0, count: 1, lifetime: 10}
      })

    trip = fn tripped_state, _issue ->
      update_in(tripped_state.dispatch_recovery.codex_thrash_budget[@issue_id], &Map.put(&1, :trip_observed, true))
    end

    assert {:error, :thrash_circuit_open, rejected_state} =
             Dispatcher.admit_redispatch(state, issue, nil,
               now_ms: @window_ms + 1,
               trip_fun: trip
             )

    assert %{tripped: :lifetime, trip_observed: true} =
             thrash_budget(rejected_state)[@issue_id]
  end

  # Drives a reset control call the way the control caller does: an
  # Orchestrator step replies with tracker I/O, the caller performs it, and the
  # next step gets the result.
  defp reset_control_call(state, identifier), do: drive_control_step(PauseResume.tracker_control_call(state, :reset_budget, identifier))

  defp drive_control_step({:reply, {:tracker_io, {action, identifier, stage}, function, args}, state}) do
    result = apply(Aiur.Tracker, function, args)
    drive_control_step(PauseResume.tracker_control_call(state, action, identifier, stage, result))
  end

  defp drive_control_step(reply), do: reply
end

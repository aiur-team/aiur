Code.require_file("../../../support/dispatch_policy_fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.DispatchPolicy.DecisionGateTest do
  use Aiur.TestSupport

  import Aiur.TestSupport.DispatchPolicyFixture

  alias Aiur.BuildQueue.Hints
  alias Aiur.Workflow
  alias Aiur.Orchestrator.{DispatchPolicy, State}

  describe "blocked-on-decision dispatch gate (#1965)" do
    test "a held issue is declined with :build_queue_hold before other state gates" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 5)
      :ets.new(Hints.table_name(), [:named_table, :set])
      :ets.insert(Hints.table_name(), {"held", {0, 0}, true})
      ticket = issue("held", [])
      state = %State{max_concurrent_agents: 5, blocked_ticket_ids: MapSet.new([ticket.id])}
      active = DispatchPolicy.active_state_set()
      terminal = DispatchPolicy.terminal_state_set()

      assert DispatchPolicy.dispatch_decision(ticket, state, active, terminal, MapSet.new()) == {:skip, :build_queue_hold}
      assert DispatchPolicy.dispatch_decision(ticket, state, active, terminal, state.blocked_ticket_ids) == {:skip, :build_queue_hold}
      assert DispatchPolicy.manual_resume_decision(ticket, state) == {:skip, :build_queue_hold}

      :ets.insert(Hints.table_name(), {ticket.id, {0, 0}, false})
      assert DispatchPolicy.dispatch_decision(ticket, state, active, terminal, MapSet.new()) == :dispatch
      assert DispatchPolicy.manual_resume_decision(ticket, %{state | blocked_ticket_ids: MapSet.new()}) == :dispatch
    end

    test "a ticket with an open blocking Command is skipped with :blocked_on_decision" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 5)
      state = %State{max_concurrent_agents: 5}
      ticket = issue("blocked", [])
      active = DispatchPolicy.active_state_set()
      terminal = DispatchPolicy.terminal_state_set()

      assert DispatchPolicy.dispatch_decision(ticket, state, active, terminal, MapSet.new([ticket.id])) ==
               {:skip, :blocked_on_decision}

      assert DispatchPolicy.dispatch_decision(
               ticket,
               %{state | blocked_ticket_ids: MapSet.new([ticket.id])}
             ) == {:skip, :blocked_on_decision}

      # A blocked ticket is also not a dispatch candidate, so it does not count
      # as queued-work demand.
      refute DispatchPolicy.dispatch_candidate?(ticket, state, active, terminal, MapSet.new([ticket.id]))
      refute DispatchPolicy.dispatch_candidate?(ticket, %{state | blocked_ticket_ids: MapSet.new([ticket.id])})
      refute DispatchPolicy.queued_dispatch_demand?([ticket], %{state | blocked_ticket_ids: MapSet.new([ticket.id])})
    end

    test "a non-blocking Command does not gate dispatch" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 5)
      state = %State{max_concurrent_agents: 5}
      ticket = issue("not-blocked", [])
      active = DispatchPolicy.active_state_set()
      terminal = DispatchPolicy.terminal_state_set()

      # The ticket absent from the blocked set dispatches normally.
      assert DispatchPolicy.dispatch_decision(ticket, state, active, terminal, MapSet.new(["other"])) ==
               :dispatch

      # And a nil blocked set (never computed this cycle) never gates.
      assert DispatchPolicy.dispatch_decision(ticket, state, active, terminal, nil) == :dispatch
      assert DispatchPolicy.dispatch_decision(ticket, state) == :dispatch
    end

    test "answering or dismissing the Command releases the ticket on the next poll" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 5)
      state = %State{max_concurrent_agents: 5}
      ticket = issue("released", [])
      active = DispatchPolicy.active_state_set()
      terminal = DispatchPolicy.terminal_state_set()

      assert DispatchPolicy.dispatch_decision(ticket, state, active, terminal, MapSet.new([ticket.id])) ==
               {:skip, :blocked_on_decision}

      # The next cycle's store read no longer contains the answered/dismissed
      # Command, so the same ticket is dispatchable again.
      assert DispatchPolicy.dispatch_decision(ticket, state, active, terminal, MapSet.new()) ==
               :dispatch
    end

    test "an unreadable decision store fails closed for dispatch" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 5)
      state = %State{max_concurrent_agents: 5}
      ticket = issue("store-down", [])
      active = DispatchPolicy.active_state_set()
      terminal = DispatchPolicy.terminal_state_set()

      assert DispatchPolicy.dispatch_decision(ticket, state, active, terminal, :unavailable) ==
               {:skip, :blocked_on_decision}

      refute DispatchPolicy.dispatch_candidate?(ticket, state, active, terminal, :unavailable)
      refute DispatchPolicy.queued_dispatch_demand?([ticket], %{state | blocked_ticket_ids: :unavailable})
    end

    test "blocked_on_decision?/2 is fail-closed for dispatch but strict for the Reconciler" do
      ticket = issue("reconciler-check", [])

      # Dispatch-facing: an unreadable store holds the ticket.
      assert DispatchPolicy.blocked_on_decision?(ticket, MapSet.new([ticket.id]))
      assert DispatchPolicy.blocked_on_decision?(ticket, :unavailable)
      refute DispatchPolicy.blocked_on_decision?(ticket, MapSet.new(["other"]))
      refute DispatchPolicy.blocked_on_decision?(ticket, nil)
    end
  end
end

defmodule Aiur.Orchestrator.InterruptsTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.{Interrupts, State}

  test "REPL pane interrupt decision follows the queue and pause state" do
    assert Interrupts.pane_interrupt_action(false, 2) == :interrupt
    assert Interrupts.pane_interrupt_action(false, 0) == :pause
    assert Interrupts.pane_interrupt_action(true, 0) == :close_pane
    assert Interrupts.pane_interrupt_action(true, 2) == :close_pane
  end

  test "pane-less interrupt decision preserves working agents" do
    assert Interrupts.pane_interrupt_action_no_pane(false, true) == :send_interrupt
    assert Interrupts.pane_interrupt_action_no_pane(false, false) == :pause
    assert Interrupts.pane_interrupt_action_no_pane(true, true) == :close_pane
    assert Interrupts.pane_interrupt_action_no_pane(true, false) == :close_pane
  end

  test "pane_interrupt_reply on deactivated entry without repl_pane_id returns close_pane and removes from running" do
    deactivated_entry = %{
      identifier: "730",
      control: %{status: :deactivated},
      pid: nil,
      ref: nil
    }

    state = %State{running: %{"issue-730" => deactivated_entry}}

    assert {{:ok, :close_pane}, new_state} = Interrupts.pane_interrupt_reply(state, "730")
    refute Map.has_key?(new_state.running, "issue-730")
  end

  test "pane_interrupt_reply on deactivated entry WITH repl_pane_id returns close_pane and removes from running" do
    # A persistent-REPL agent whose pane was kept open for inspection has
    # repl_pane_id set. Before the fix it took the REPL branch and never
    # reached the deactivated-eviction path.
    deactivated_entry = %{
      identifier: "730",
      control: %{status: :deactivated},
      repl_pane_id: "%42",
      pid: nil,
      ref: nil
    }

    state = %State{running: %{"issue-730" => deactivated_entry}}

    assert {{:ok, :close_pane}, new_state} = Interrupts.pane_interrupt_reply(state, "730")
    refute Map.has_key?(new_state.running, "issue-730")
  end

  test "pane_interrupt_reply on paused entry WITH repl_pane_id does NOT remove from running" do
    # A paused agent with a live pane must not be evicted — the operator has
    # paused it intentionally and a second Ctrl+C closes the pane via the
    # :close_pane action, but the entry stays in running.
    paused_entry = %{
      identifier: "730",
      control: %{status: :paused},
      repl_pane_id: "%42",
      pid: nil,
      ref: nil
    }

    state = %State{running: %{"issue-730" => paused_entry}}

    # Queue depth 0 + paused → :close_pane, but the entry is NOT deleted
    assert {{:ok, :close_pane}, new_state} = Interrupts.pane_interrupt_reply(state, "730")
    assert Map.has_key?(new_state.running, "issue-730")
  end
end

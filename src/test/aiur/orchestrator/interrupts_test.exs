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

  test "pane_interrupt_reply on deactivated entry returns close_pane and removes from running" do
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
end

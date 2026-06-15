defmodule Aiur.OrchestratorInterruptTest do
  use Aiur.TestSupport

  alias Aiur.Opencode.ActiveTurns

  defp running_entry(identifier, extra \\ %{}) do
    Map.merge(
      %{
        pid: self(),
        ref: make_ref(),
        identifier: identifier,
        issue: %Issue{id: identifier, identifier: identifier, state: "In Progress", title: "Issue #{identifier}"},
        control: %{can_interrupt: true, safe_checkpoints: [], status: :working}
      },
      extra
    )
  end

  setup do
    pid = Process.whereis(Orchestrator)
    original = :sys.get_state(pid)
    :sys.replace_state(pid, fn state -> %{state | running: %{}} end)
    on_exit(fn -> if Process.alive?(pid), do: :sys.replace_state(pid, fn _ -> original end) end)
    {:ok, orchestrator: pid}
  end

  test "interrupt of an unknown issue reports not_running" do
    assert {:error, :not_running} = Orchestrator.interrupt_agent("MISSING")
  end

  test "interrupt of a backend without a REPL pane is unsupported", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | running: %{"codex-1" => running_entry("codex-1")}}
    end)

    assert {:error, :interrupt_not_supported} = Orchestrator.interrupt_agent("codex-1")
  end

  describe "pane_interrupt_action/2" do
    test "queued message drains via interrupt" do
      assert :interrupt = Orchestrator.pane_interrupt_action(false, 1)
      assert :interrupt = Orchestrator.pane_interrupt_action(false, 3)
    end

    test "idle agent pauses" do
      assert :pause = Orchestrator.pane_interrupt_action(false, 0)
    end

    test "already-paused agent closes the pane regardless of queue" do
      assert :close_pane = Orchestrator.pane_interrupt_action(true, 0)
      assert :close_pane = Orchestrator.pane_interrupt_action(true, 2)
    end
  end

  describe "pane_interrupt_action_no_pane/2" do
    test "idle agent pauses, paused agent closes the pane" do
      # working? = false. opencode/codex own their queue and turn; the only
      # turn-activity signal Aiur has is ActiveTurns. With no live turn the
      # agent is genuinely idle: first press pauses, second press (paused)
      # closes.
      assert :pause = Orchestrator.pane_interrupt_action_no_pane(false, false)
      assert :close_pane = Orchestrator.pane_interrupt_action_no_pane(true, false)
    end

    test "a working agent gets opencode's native interrupt instead of pausing" do
      # working? = true. A Ctrl+C mid-turn must forward opencode's interrupt
      # (the bridge sends Esc) so its queued operator message drains and the
      # agent keeps working — never the cosmetic pause that left codex
      # streaming, and never a close that drops the pending input.
      assert :send_interrupt = Orchestrator.pane_interrupt_action_no_pane(false, true)
    end

    test "a paused agent closes even while a turn is still active" do
      # Paused wins: a second press always closes, regardless of turn state.
      assert :close_pane = Orchestrator.pane_interrupt_action_no_pane(true, true)
    end
  end

  describe "pane_interrupt/1" do
    test "unknown issue reports not_running" do
      assert {:error, :not_running} = Orchestrator.pane_interrupt("MISSING")
    end

    test "pane-less backend pauses on first press, then closes on the second",
         %{orchestrator: pid} do
      # Codex/opencode agents have no REPL pane to hardware-interrupt, but a
      # Ctrl+C must not nuke the pane on the first press. The first press
      # pauses (pane stays open); a second press on the paused agent closes.
      :sys.replace_state(pid, fn state ->
        %{state | running: %{"codex-1" => running_entry("codex-1")}}
      end)

      assert {:ok, :paused} = Orchestrator.pane_interrupt("codex-1")
      assert get_in(:sys.get_state(pid).running, ["codex-1", :control, :status]) == :paused

      assert {:ok, :close_pane} = Orchestrator.pane_interrupt("codex-1")
    end

    test "pane-less backend mid-turn forwards opencode's interrupt instead of pausing",
         %{orchestrator: pid} do
      # The regression: a Ctrl+C on a working opencode agent flipped a cosmetic
      # pause while codex kept streaming, and never drained the operator's
      # queued message (opencode owns that queue, invisible to Aiur). The live
      # turn registers in ActiveTurns; a press while a turn is active must
      # return :send_interrupt so the bridge forwards Esc, and Aiur must leave
      # the agent :working (no optimistic pause flip).
      entry = running_entry("codex-1")
      ActiveTurns.put("codex-1", "turn-1")
      on_exit(fn -> ActiveTurns.mark_closed("codex-1", "turn-1", :test_cleanup) end)

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"codex-1" => entry}}
      end)

      assert {:ok, :send_interrupt} = Orchestrator.pane_interrupt("codex-1")
      assert get_in(:sys.get_state(pid).running, ["codex-1", :control, :status]) == :working
    end

    test "paused REPL agent closes its pane", %{orchestrator: pid} do
      entry =
        running_entry("repl-1", %{
          repl_pane_id: "%9",
          control: %{can_interrupt: true, safe_checkpoints: [], status: :paused}
        })

      :sys.replace_state(pid, fn state -> %{state | running: %{"repl-1" => entry}} end)

      assert {:ok, :close_pane} = Orchestrator.pane_interrupt("repl-1")
    end

    test "pausing a working REPL agent flips status so a second press closes the pane",
         %{orchestrator: pid} do
      entry =
        running_entry("repl-1", %{
          repl_pane_id: "%9",
          control: %{can_interrupt: true, safe_checkpoints: [], status: :working}
        })

      :sys.replace_state(pid, fn state -> %{state | running: %{"repl-1" => entry}} end)

      # First Ctrl+C on a working, queue-empty agent pauses it and flips the
      # recorded status optimistically — an idle agent emits no async
      # worker confirmation, so the close branch would otherwise be unreachable.
      assert {:ok, :paused} = Orchestrator.pane_interrupt("repl-1")
      assert get_in(:sys.get_state(pid).running, ["repl-1", :control, :status]) == :paused

      # Second Ctrl+C, now that the agent reads as paused, closes the pane.
      assert {:ok, :close_pane} = Orchestrator.pane_interrupt("repl-1")
    end

    test "queued message on a REPL agent never closes the pane even if the interrupt fails",
         %{orchestrator: pid} do
      # Dual-surface agent (opencode pane + repl pane) carrying a queued
      # operator message. Ctrl+C routes through the repl_pane_id branch, which
      # fires a hardware interrupt. `:interrupt` is only ever chosen when a
      # message is queued, so a failed interrupt (repl pane already gone, tmux
      # hiccup) must still keep the pane open for the message to fold — never
      # propagate the error, which the bridge controller maps to :close_pane
      # and the helper turns into a kill-pane, dropping the queued input.
      entry =
        running_entry("repl-1", %{
          repl_pane_id: "%9",
          control: %{can_interrupt: true, safe_checkpoints: [], status: :working}
        })

      :sys.replace_state(pid, fn state ->
        {queue_store, _item} =
          Aiur.AgentQueueStore.enqueue(state.queue_store, %{
            target_issue_identifier: "repl-1",
            source: :operator,
            category: :operator_message,
            event_type: :operator_message,
            body: %{text: "hi from opencode"}
          })

        %{state | running: %{"repl-1" => entry}, queue_store: queue_store}
      end)

      # No tmux server backs %9 in the test env, so Tmux.send_interrupt fails.
      assert {:ok, :interrupted} = Orchestrator.pane_interrupt("repl-1")
    end
  end

  describe "pane_interrupt_by_pane_id/1" do
    test "resolves a REPL pane by its pane id and applies the 3-state decision",
         %{orchestrator: pid} do
      # The Ctrl+C bridge only carries the tmux pane id, not the issue. A
      # claude-repl/RC pane is not an opencode slot, so the opencode
      # SlotRegistry can't resolve it — without a repl_pane_id→issue lookup
      # the bridge collapsed to a raw kill-pane on the first press. This maps
      # the pane back to its running entry so the pause→close flow applies.
      entry =
        running_entry("repl-1", %{
          repl_pane_id: "%9",
          control: %{can_interrupt: true, safe_checkpoints: [], status: :working}
        })

      :sys.replace_state(pid, fn state -> %{state | running: %{"repl-1" => entry}} end)

      assert {:ok, :paused} = Orchestrator.pane_interrupt_by_pane_id("%9")
      assert get_in(:sys.get_state(pid).running, ["repl-1", :control, :status]) == :paused

      assert {:ok, :close_pane} = Orchestrator.pane_interrupt_by_pane_id("%9")
    end

    test "unknown pane reports no_pane_agent" do
      assert {:error, :no_pane_agent} = Orchestrator.pane_interrupt_by_pane_id("%nope")
    end
  end
end

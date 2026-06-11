defmodule Aiur.OrchestratorInterruptTest do
  use Aiur.TestSupport

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

  describe "pane_interrupt_action_no_pane/1" do
    test "active agent pauses, paused agent closes the pane" do
      assert :pause = Orchestrator.pane_interrupt_action_no_pane(false)
      assert :close_pane = Orchestrator.pane_interrupt_action_no_pane(true)
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
  end
end

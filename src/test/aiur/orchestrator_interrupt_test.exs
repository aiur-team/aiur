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

  describe "pane_interrupt_action_no_pane/2" do
    test "active agent pauses, paused agent closes the pane when queue is empty" do
      assert :pause = Orchestrator.pane_interrupt_action_no_pane(false, 0)
      assert :close_pane = Orchestrator.pane_interrupt_action_no_pane(true, 0)
    end

    test "a queued message takes priority over both pause and close" do
      # Pane-less backends fold operator input at the next turn boundary.
      # When a message is already queued, Ctrl+C must let it deliver rather
      # than pause an active agent or close a paused one out from under the
      # pending message — otherwise the operator's queued input is lost.
      assert :deliver_queue = Orchestrator.pane_interrupt_action_no_pane(false, 1)
      assert :deliver_queue = Orchestrator.pane_interrupt_action_no_pane(true, 1)
      assert :deliver_queue = Orchestrator.pane_interrupt_action_no_pane(false, 3)
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

    test "pane-less backend with a queued message delivers it instead of pausing",
         %{orchestrator: pid} do
      # The Bug 2 regression: a Ctrl+C on an opencode agent with a queued
      # operator message closed/paused the pane, dropping the queued input.
      # With queue-first semantics the press leaves the agent working so the
      # queued message folds at its next turn boundary.
      entry = running_entry("codex-1")

      :sys.replace_state(pid, fn state ->
        {queue_store, _item} =
          Aiur.AgentQueueStore.enqueue(state.queue_store, %{
            target_issue_identifier: "codex-1",
            source: :operator,
            category: :operator_message,
            event_type: :operator_message,
            body: %{text: "do the thing"}
          })

        %{state | running: %{"codex-1" => entry}, queue_store: queue_store}
      end)

      assert {:ok, :deliver_queue} = Orchestrator.pane_interrupt("codex-1")
      # The agent stays working — no optimistic pause flip.
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
  end
end

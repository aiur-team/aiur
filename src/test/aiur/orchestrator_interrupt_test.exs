defmodule Aiur.OrchestratorInterruptTest do
  use Aiur.TestSupport

  alias Aiur.Opencode.ActiveTurns
  alias Aiur.TrackerIdentity

  defp running_entry(identifier, extra \\ %{}) do
    Map.merge(
      %{
        pid: self(),
        ref: make_ref(),
        identifier: identifier,
        issue: %Issue{
          id: identifier,
          identifier: identifier,
          state: "In Progress",
          title: "Issue #{identifier}",
          tracker_identity: tracker_identity(identifier)
        },
        control: %{
          can_interrupt: true,
          safe_checkpoints: [],
          application_confirmation: :confirmed,
          generation: 101,
          version: 0,
          status: :working
        }
      },
      extra
    )
  end

  setup do
    pid = Process.whereis(Orchestrator)
    original = :sys.get_state(pid)
    store_path = Path.join(System.tmp_dir!(), "aiur_interrupt_controls_#{System.pid()}-#{System.unique_integer([:positive])}.json")
    previous_store_path = Application.get_env(:aiur, :control_lifecycle_store_path)
    Application.put_env(:aiur, :control_lifecycle_store_path, store_path)
    :sys.replace_state(pid, fn state -> %{state | running: %{}} end)

    on_exit(fn ->
      if is_nil(previous_store_path),
        do: Application.delete_env(:aiur, :control_lifecycle_store_path),
        else: Application.put_env(:aiur, :control_lifecycle_store_path, previous_store_path)

      File.rm(store_path)
      if Process.alive?(pid), do: :sys.replace_state(pid, fn _ -> original end)
    end)

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

    test "pane-less backend reports pause requested until matching worker evidence applies it",
         %{orchestrator: pid} do
      # Codex/opencode agents have no REPL pane to hardware-interrupt. The
      # first Ctrl+C routes a correlated pause and keeps the agent working
      # until that worker generation confirms the transition.
      entry = running_entry("codex-1")

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"codex-1" => entry}}
      end)

      assert {:ok, :pause_requested} = Orchestrator.pane_interrupt("codex-1")
      assert get_in(:sys.get_state(pid).running, ["codex-1", :control, :status]) == :working
      assert_receive {:pause_agent, request_id, 101}

      send(pid, {:worker_control_state, "codex-1", :paused, %{request_id: request_id, generation: 101}})
      assert eventually(fn -> get_in(:sys.get_state(pid).running, ["codex-1", :control, :status]) == :paused end)

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
      identifier = "codex-#{System.unique_integer([:positive])}"
      turn_id = "turn-#{System.unique_integer([:positive])}"
      entry = running_entry(identifier)
      ActiveTurns.put(identifier, turn_id)
      on_exit(fn -> ActiveTurns.mark_closed(identifier, turn_id, :test_cleanup) end)

      :sys.replace_state(pid, fn state ->
        %{state | running: %{identifier => entry}}
      end)

      assert {:ok, :send_interrupt} = Orchestrator.pane_interrupt(identifier)
      assert get_in(:sys.get_state(pid).running, [identifier, :control, :status]) == :working
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

    test "pausing a working REPL agent remains requested until worker confirmation",
         %{orchestrator: pid} do
      entry =
        running_entry("repl-1")
        |> Map.put(:repl_pane_id, "%9")

      :sys.replace_state(pid, fn state -> %{state | running: %{"repl-1" => entry}} end)

      assert {:ok, :pause_requested} = Orchestrator.pane_interrupt("repl-1")
      assert get_in(:sys.get_state(pid).running, ["repl-1", :control, :status]) == :working
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
        running_entry("repl-1")
        |> Map.put(:repl_pane_id, "%9")

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
        running_entry("repl-1")
        |> Map.put(:repl_pane_id, "%9")

      :sys.replace_state(pid, fn state -> %{state | running: %{"repl-1" => entry}} end)

      assert {:ok, :pause_requested} = Orchestrator.pane_interrupt_by_pane_id("%9")
      assert get_in(:sys.get_state(pid).running, ["repl-1", :control, :status]) == :working
    end

    test "unknown pane reports no_pane_agent" do
      assert {:error, :no_pane_agent} = Orchestrator.pane_interrupt_by_pane_id("%nope")
    end
  end

  defp tracker_identity(identifier) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: Aiur.TestSupport.github_owner(),
      repository: Aiur.TestSupport.github_repository_name(),
      provider_id: "I_kwDO#{identifier}",
      identifier: "101",
      reason: nil
    }
  end

  defp eventually(fun, attempts \\ 30)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end

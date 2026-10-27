defmodule Aiur.Orchestrator.InterruptsTest do
  use ExUnit.Case, async: false

  import Aiur.TestSupport, only: [receive_barrier: 1]

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

  setup do
    start_supervised!({Aiur.Tmux, name: Aiur.Tmux, transport: {:mock, self(), :infinity}})
    :ok
  end

  test "pane interrupt still fires before session execution is recorded" do
    state = pane_state(nil)
    task = Task.async(fn -> Interrupts.interrupt_agent_reply(state, "pane-1") end)
    receive_barrier({:tmux_mock_out, command})
    send(Aiur.Tmux, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert Task.await(task) == :ok
    assert command == "send-keys -t %2 C-c"
  end

  test "pane interrupt uses the running backend instead of assuming the pane adapter" do
    assert Interrupts.interrupt_agent_reply(pane_state("codex"), "pane-1") ==
             {:error, :interrupt_not_supported}

    refute_received {:tmux_mock_out, _}
  end

  test "queued pane interrupt dispatches through the running backend and keeps callback errors best effort" do
    state = pane_state("claude-repl") |> with_queued_message()
    task = Task.async(fn -> Interrupts.pane_interrupt_reply(state, "pane-1") end)
    receive_barrier({:tmux_mock_out, command})
    send(Aiur.Tmux, {:tmux_mock_data, "%begin 1 1 0\n%error 1 1 0\n"})
    assert Task.await(task) == {{:ok, :interrupted}, state}
    assert command == "send-keys -t %2 C-c"

    unsupported = pane_state("codex") |> with_queued_message()
    assert Interrupts.pane_interrupt_reply(unsupported, "pane-1") == {{:ok, :interrupted}, unsupported}
    refute_received {:tmux_mock_out, _}
  end

  defp pane_state(backend) do
    execution = if backend, do: %{backend: backend}
    %State{running: %{"1" => %{identifier: "pane-1", repl_pane_id: "%2", session_execution: execution}}}
  end

  defp with_queued_message(state) do
    {store, _item} =
      Aiur.AgentQueueStore.enqueue(Aiur.AgentQueueStore.new(), %{
        target_issue_identifier: "pane-1",
        source: :operator,
        category: :operator_message,
        event_type: :operator_message,
        body: %{text: "continue"}
      })

    %{state | queue_store: store}
  end
end

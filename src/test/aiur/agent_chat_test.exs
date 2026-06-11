defmodule Aiur.AgentChatTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentChat
  alias Aiur.Orchestrator

  test "send delegates to orchestrator control path" do
    assert {:error, reason} = AgentChat.send("MT-CHAT", "hello")
    assert reason in [:unavailable, :no_running_agent]
  end

  test "pause delegates to orchestrator control path" do
    assert {:error, reason} = AgentChat.pause("MT-CHAT")
    assert reason in [:unavailable, :no_running_agent]
  end

  test "resume delegates to orchestrator control path" do
    assert {:error, reason} = AgentChat.resume("MT-CHAT")
    assert reason in [:unavailable, :no_running_agent]
  end

  test "interrupt delegates to orchestrator control path" do
    assert {:error, reason} = AgentChat.interrupt("MT-CHAT")
    assert reason in [:unavailable, :not_running]
  end

  test "pane_interrupt reports no_pane_agent for an unknown pane" do
    assert {:error, :no_pane_agent} = AgentChat.pane_interrupt("%no-such-pane")
  end

  test "pane_interrupt resolves a claude-repl/RC pane that the opencode registry can't" do
    # The RC agent (claude-repl backend) has a repl_pane_id but no opencode
    # slot, so SlotRegistry.find_by_pane_id returns :not_found. The bridge must
    # still route the press through the orchestrator's 3-state decision rather
    # than collapsing to no_pane_agent (which the helper turns into kill-pane).
    pid = Process.whereis(Orchestrator)
    original = :sys.get_state(pid)

    entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: "repl-rc",
      issue: %Aiur.Issue{
        id: "repl-rc",
        identifier: "repl-rc",
        state: "In Progress",
        title: "RC agent"
      },
      repl_pane_id: "%rc9",
      control: %{can_interrupt: true, safe_checkpoints: [], status: :working}
    }

    :sys.replace_state(pid, fn state -> %{state | running: %{"repl-rc" => entry}} end)
    on_exit(fn -> if Process.alive?(pid), do: :sys.replace_state(pid, fn _ -> original end) end)

    assert {:ok, :paused} = AgentChat.pane_interrupt("%rc9")
  end

  test "capabilities delegates to orchestrator control path" do
    assert {:ok, capabilities} = AgentChat.capabilities("MT-CHAT")
    assert capabilities.accepted_delivery_policies == [:checkpoint]
    assert capabilities.accepts_operator_messages == false
  end
end

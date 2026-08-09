defmodule Aiur.AgentChatTest do
  use ExUnit.Case, async: false

  import Aiur.TestSupport, only: [github_owner: 0, github_repository: 0, github_repository_name: 0]

  alias Aiur.AgentChat
  alias Aiur.Orchestrator
  alias Aiur.TrackerIdentity

  test "fixture identity components come from the canonical repository slug" do
    identity = tracker_identity()
    assert "#{identity.owner}/#{identity.repository}" == github_repository()
  end

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

    store_path = Path.join(System.tmp_dir!(), "aiur_agent_chat_controls_#{System.unique_integer([:positive])}.json")
    previous_store_path = Application.get_env(:aiur, :control_lifecycle_store_path)
    Application.put_env(:aiur, :control_lifecycle_store_path, store_path)

    entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: "repl-rc",
      issue: %Aiur.Issue{
        id: "repl-rc",
        identifier: "repl-rc",
        state: "In Progress",
        title: "RC agent",
        tracker_identity: tracker_identity()
      },
      repl_pane_id: "%rc9",
      control: %{
        can_interrupt: true,
        safe_checkpoints: [],
        application_confirmation: :confirmed,
        generation: 101,
        version: 0,
        status: :working
      }
    }

    :sys.replace_state(pid, fn state -> %{state | running: %{"repl-rc" => entry}} end)

    on_exit(fn ->
      if is_nil(previous_store_path),
        do: Application.delete_env(:aiur, :control_lifecycle_store_path),
        else: Application.put_env(:aiur, :control_lifecycle_store_path, previous_store_path)

      File.rm(store_path)
      if Process.alive?(pid), do: :sys.replace_state(pid, fn _ -> original end)
    end)

    assert {:ok, :pause_requested} = AgentChat.pane_interrupt("%rc9")
  end

  test "capabilities delegates to orchestrator control path" do
    assert {:ok, capabilities} = AgentChat.capabilities("MT-CHAT")
    assert capabilities.accepted_delivery_policies == [:checkpoint]
    assert capabilities.accepts_operator_messages == false
  end

  defp tracker_identity do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: github_owner(),
      repository: github_repository_name(),
      provider_id: "I_kwDOreplrc",
      identifier: "101",
      reason: nil
    }
  end
end

defmodule Aiur.AgentChatTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentChat

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

  test "capabilities delegates to orchestrator control path" do
    assert {:ok, capabilities} = AgentChat.capabilities("MT-CHAT")
    assert capabilities.accepted_delivery_policies == [:checkpoint]
    assert capabilities.accepts_operator_messages == false
  end
end

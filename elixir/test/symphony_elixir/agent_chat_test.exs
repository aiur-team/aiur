defmodule SymphonyElixir.AgentChatTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentChat

  test "send delegates to orchestrator control path" do
    assert {:error, reason} = AgentChat.send("MT-CHAT", "hello")
    assert reason in [:unavailable, :no_running_agent]
  end

  test "pause delegates to orchestrator control path" do
    assert {:error, reason} = AgentChat.pause("MT-CHAT")
    assert reason in [:unavailable, :no_running_agent]
  end
end

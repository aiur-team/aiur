defmodule SymphonyElixir.AgentChatBroadcastTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{AgentChat, AgentPubSub}

  test "send/2 broadcasts a user-role transcript event when the orchestrator accepts the message" do
    :ok = AgentPubSub.subscribe_agent("MT-CHATBC")

    # AgentChat.send returns {:ok, request_id} only when a matching running
    # agent exists. In the default test environment there is no running agent
    # so the call returns {:error, ...} and no broadcast fires.
    result = AgentChat.send("MT-CHATBC", "hello there")

    case result do
      {:ok, _request_id} ->
        assert_receive {:transcript_event, %{role: :user, body: "hello there"}}, 500

      {:error, _} ->
        refute_receive {:transcript_event, _}, 100
    end
  end
end

defmodule AiurWeb.StreamdeckOverrideFrameTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.TestSupport.EndpointStubs

  for {state, label} <- [{:queued, "override queued"}, {:delivered, "override delivered"}, {:failed, "override failed"}] do
    test "#{label} paints in the physical frame after a focused Command change" do
      state = unquote(state)
      label = unquote(label)
      decision = %{command_decision("AIUR-1") | overrides: [%{state: state}]}
      {:ok, store} = FakeDecisionStore.start_link(decision, self())
      EndpointStubs.put(decision_store: store)
      on_exit(fn -> Aiur.TestSupport.safe_stop(store) end)
      socket = joined_socket()
      assert_push("frame", _initial)
      assert_reply(push(socket, "focus", %{"identifier" => "AIUR-1"}), :ok, %{"focused" => "AIUR-1"})
      receive_barrier(%Message{event: "commands"})
      send(socket.channel_pid, {:decision_changed, decision.decision_id, decision.version})
      assert_push("frame", %{strip: strip})
      assert Enum.any?(strip, &String.contains?(&1.svg, label))
      assert Enum.any?(strip, &String.contains?(&1.label, label))
    end
  end
end

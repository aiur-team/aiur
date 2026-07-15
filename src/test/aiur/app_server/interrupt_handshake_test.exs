defmodule Aiur.AppServer.InterruptHandshakeTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.InterruptHandshake

  test "becomes ready after acknowledgement then idle" do
    assert {:waiting, state} = InterruptHandshake.acknowledge(state(), %{"id" => 1})

    assert {:ready, state, payload} =
             InterruptHandshake.observe_idle(state, %{"status" => "idle"})

    assert state.interrupt_acknowledged?
    assert state.interrupt_idle_seen?
    assert payload["status"] == "interrupted"
  end

  test "becomes ready after idle then acknowledgement" do
    assert {:waiting, state} = InterruptHandshake.observe_idle(state(), %{"status" => "idle"})

    assert {:ready, state, payload} =
             InterruptHandshake.acknowledge(state, %{"id" => 1})

    assert state.interrupt_acknowledged?
    assert state.interrupt_idle_seen?
    assert payload["status"] == "interrupted"
  end

  defp state do
    %{
      interrupt_action: :pause,
      interrupt_acknowledged?: false,
      interrupt_idle_seen?: false,
      pending_interrupt_request_id: 1
    }
  end
end

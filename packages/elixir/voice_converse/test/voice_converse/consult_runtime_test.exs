defmodule VoiceConverse.ConsultRuntimeTest do
  use ExUnit.Case, async: true

  alias VoiceConverse.Session.Runtime
  alias VoiceConverse.Testing.FakeProvider

  test "context received during reconnect is delivered in order when the provider returns" do
    state = %{provider: FakeProvider, provider_ref: nil, pending_consult_context: []}
    state = Runtime.consult_context(state, "First answer")
    state = Runtime.consult_context(state, "Second answer")
    assert state.pending_consult_context == ["First answer", "Second answer"]
    {:ok, provider} = FakeProvider.open(%{owner: self(), fake: []})
    on_exit(fn -> if Process.alive?(provider), do: Agent.stop(provider) end)
    state = state |> Map.put(:provider_ref, provider) |> Map.put(:state, :reconnecting)
    state = Runtime.consult_context(state, "Third answer")
    assert FakeProvider.calls(provider) == []
    state = Runtime.flush_consult_context(state)
    assert state.pending_consult_context == []

    assert FakeProvider.calls(provider) == [
             {:send_context, "First answer"},
             {:send_context, "Second answer"},
             {:send_context, "Third answer"}
           ]
  end
end

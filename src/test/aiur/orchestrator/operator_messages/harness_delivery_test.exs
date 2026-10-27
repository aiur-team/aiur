defmodule Aiur.Orchestrator.OperatorMessages.HarnessDeliveryTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentQueueStore, Issue}
  alias Aiur.Harness.Capabilities, as: HarnessCapabilities
  alias Aiur.Orchestrator.OperatorMessages.Capabilities
  alias Aiur.Orchestrator.State

  test "harness delivery follows the running session after a REPL fallback" do
    state = state_for("claude-repl", %{backend: "claude"})
    assert Capabilities.harness_delivery(state, "42") == descriptor("claude", :session)
  end

  test "harness delivery follows the running session after RC promotion" do
    state = state_for("claude", %{backend: "claude-repl"})
    assert Capabilities.harness_delivery(state, "42") == descriptor("claude-repl", :session)
  end

  test "harness delivery marks dispatch before session start" do
    for session <- [nil, %{}, %{backend: nil}] do
      state = state_for("claude-repl", session)
      assert Capabilities.harness_delivery(state, "42") == descriptor("claude-repl", :dispatch)
    end

    state = state_for("codex", nil)
    entry = Map.delete(state.running["issue-42"], :session_execution)
    assert Capabilities.harness_delivery(state, "42", entry) == descriptor("codex", :dispatch)
  end

  test "an unregistered session backend stays unknown instead of using dispatch" do
    state = state_for("claude-repl", %{backend: "unknown"})

    assert Capabilities.harness_delivery(state, "42") == %{
             harness_id: "unknown",
             source: :session,
             primitives: :unknown,
             callbacks: :unknown
           }
  end

  test "an unregistered dispatch backend stays unknown" do
    state = state_for("unregistered", nil)

    assert Capabilities.harness_delivery(state, "42") == %{
             harness_id: "unregistered",
             source: :dispatch,
             primitives: :unknown,
             callbacks: :unknown
           }
  end

  test "harness delivery is nil without a running agent" do
    state = state_for("codex", %{backend: "codex"})
    assert Capabilities.harness_delivery(state, "missing") == nil
    assert Capabilities.harness_delivery(state, "42", nil) == nil
  end

  defp descriptor(backend, source) do
    {:ok, primitives} = HarnessCapabilities.delivery_primitives(backend)
    %{harness_id: backend, source: source, primitives: primitives, callbacks: HarnessCapabilities.callback_support(backend)}
  end

  defp state_for(dispatched, session) do
    issue = %Issue{id: "issue-42", identifier: "42", selected_backend: dispatched}
    entry = %{identifier: "42", issue: issue, session_execution: session}
    %State{running: %{issue.id => entry}, queue_store: AgentQueueStore.new()}
  end
end

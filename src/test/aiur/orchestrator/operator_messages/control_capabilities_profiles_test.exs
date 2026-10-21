defmodule Aiur.Orchestrator.OperatorMessages.ControlCapabilitiesProfilesTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentQueueStore, CodingAgent, Issue, TrackerIdentity}
  alias Aiur.Orchestrator.{ControlLifecycle, State}
  alias Aiur.Orchestrator.OperatorMessages.Capabilities

  @moduletag :r7_characterization
  @harnesses ~w(codex claude claude-repl muse kimi fake)
  @states [:working_active, :working_idle, :sleeping, :paused, :self_paused, :self_paused_pending, :working_pending]
  @fixture Path.expand("../../../fixtures/harness_frames/control_capabilities_profiles.exs", __DIR__)

  # Future regression guard: frozen on the merge base, before harness_delivery existed.
  test "issue_control_capabilities is byte-identical for every C1 matrix profile" do
    {expected, _} = Code.eval_file(@fixture)

    actual =
      for harness <- @harnesses, entry_state <- @states, into: %{} do
        row = %{harness: harness, entry_state: entry_state}
        state = state_for(row, "42")
        {{harness, entry_state}, Capabilities.issue_control_capabilities(state, "42")}
      end

    assert actual == expected
  end

  defp state_for(row, identifier) do
    status = if row.entry_state in [:working_active, :working_idle, :working_pending], do: :working, else: :paused
    status = if row.entry_state == :sleeping, do: :sleeping, else: status

    control = %{
      status: status,
      can_interrupt: CodingAgent.can_interrupt?(row.harness),
      safe_checkpoints: CodingAgent.safe_checkpoints(row.harness),
      immediate_delivery: CodingAgent.immediate_delivery?(row.harness)
    }

    entry = %{identifier: identifier, issue: %Issue{id: identifier, identifier: identifier}, pid: self(), control: control, session_execution: %{backend: Map.get(row, :transport, row.harness)}}
    entry = if row.entry_state in [:self_paused, :self_paused_pending], do: Map.put(entry, :paused_reason, :agent_pause_request), else: entry
    state = %State{queue_store: AgentQueueStore.new(), running: %{identifier => entry}}
    if row.entry_state in [:self_paused_pending, :working_pending], do: pending_pause(state, identifier), else: state
  end

  defp pending_pause(state, identifier) do
    identity = %TrackerIdentity{status: :joinable, kind: :github, owner: "aiur-team", repository: "aiur", provider_id: identifier, identifier: "3464", reason: nil}
    attrs = %{request_id: "pause-r7", issue_id: identifier, tracker_identity: identity, action: :pause, generation: "r7", expected_status: :working, expected_version: 0, requester: :automatic}
    {:ok, _, lifecycle} = ControlLifecycle.request(state.control_lifecycle, attrs, now: ~U[2026-10-01 00:00:00Z])
    entry = Map.put(state.running[identifier], :pending_pause_reason, %{request_id: "pause-r7", reason: :agent_pause_request})
    %{state | control_lifecycle: lifecycle, running: %{identifier => entry}}
  end
end

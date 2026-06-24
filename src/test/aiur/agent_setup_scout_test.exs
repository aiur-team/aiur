defmodule Aiur.AgentSetupScoutTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentEvents, AgentSetupScout}

  test "detects repeated env-var command prefixes" do
    state = AgentSetupScout.new()
    event = command("HEX_HOME=/tmp/hex MIX_HOME=/tmp/mix mix test")

    {state, []} = AgentSetupScout.observe(state, "40", event)
    {state, []} = AgentSetupScout.observe(state, "40", event)
    {_state, [finding]} = AgentSetupScout.observe(state, "40", event)

    assert finding.title == "Pre-seed HEX_HOME, MIX_HOME for agent commands"
    assert finding.labels == ["enhancement", "agent-setup-optimization", "needs-triage"]
    assert finding.body =~ "## Pattern observed"
    assert finding.body =~ "Count: 3"
    assert finding.body =~ "## Suggested fix"
    assert finding.body =~ "## Caveat"
  end

  test "detects missing tools without hardcoding a specific tool" do
    event = AgentEvents.transcript_event(:system, "zstd: command not found", timestamp: ~U[2026-06-24 12:00:00Z])

    {_state, [finding]} = AgentSetupScout.observe(AgentSetupScout.new(), "40", event)

    assert finding.title == "Install zstd for agent workspaces"
    assert finding.body =~ "Agent hit a missing tool"
  end

  test "detects repeated stale polling commands once" do
    state = AgentSetupScout.new()
    event = command("gh pr view 123 --json state")

    {state, []} = AgentSetupScout.observe(state, "40", event)
    {state, []} = AgentSetupScout.observe(state, "40", event)
    {state, [finding]} = AgentSetupScout.observe(state, "40", event)
    {_state, []} = AgentSetupScout.observe(state, "40", event)

    assert finding.title == "Subscribe instead of polling gh pr view"
  end

  defp command(body) do
    AgentEvents.transcript_event(:command, body, timestamp: ~U[2026-06-24 12:00:00Z])
  end
end

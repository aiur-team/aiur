defmodule AiurWeb.Build.TicketStatusTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Build.TicketStatus

  test "agent states preserve the desktop taxonomy" do
    for {state, label, tone} <- [
          {"active", "Running", "active"},
          {"error", "Error", "stuck"},
          {"retries", "Retries exhausted", "stuck"},
          {"retrying", "Retrying", "queued"},
          {"command", "Awaiting command", "stuck"},
          {"paused", "Paused", "idle"},
          {"parked", "Parked", "idle"},
          {"merge-queued", "agent:merge-queued", "queued"},
          {"ci-red", "agent:ci-red", "stuck"},
          {"body-fix", "agent:body-fix", "stuck"},
          {"paused-usage-limit", "agent:paused-usage-limit", "idle"},
          {"paused-decision", "agent:paused-decision", "idle"},
          {"paused-agent", "agent:paused-agent", "idle"},
          {"blocked", "agent:blocked", "queued"},
          {"handed-off", "agent:handed-off", "idle"},
          {"usage_limited", "Paused · usage limit", "idle"},
          {"ci_wait", "Waiting for CI", "idle"}
        ] do
      assert TicketStatus.encode(%{sec: "now", agent: %{state: state}}) == %{label: label, tone: tone, agent_state: state}
    end
  end

  test "missing and unknown states do not invent a running agent" do
    for agent <- [nil, %{}, %{state: nil}, %{state: "future_state"}] do
      status = TicketStatus.encode(%{sec: "now", agent: agent})
      assert status.label == "State unknown"
      assert status.tone == "idle"
      assert status.agent_state == (agent && agent[:state])
    end

    assert TicketStatus.encode(%{}) == %{label: "State unknown", tone: "idle", agent_state: nil}
    assert TicketStatus.encode(nil) == %{label: "State unknown", tone: "idle", agent_state: nil}
  end

  test "history, planned and not queued use the same modal labels" do
    for {row, label, tone} <- [
          {%{sec: "hist", status: "done"}, "Merged", "done"},
          {%{sec: "hist", status: "failed"}, "Failed", "stuck"},
          {%{sec: "hist", status: "closed"}, "Closed", "idle"},
          {%{sec: "hist", status: "not_planned"}, "Not planned", "idle"},
          {%{sec: "hist", status: "future_state"}, "State unknown", "idle"},
          {%{sec: "plan", num: 7, qpos: 3}, "Queued · Q3", "idle"},
          {%{sec: "plan", num: 7, qpos: nil}, "Queued · Q?", "idle"},
          {%{sec: "plan", num: nil, src: %{kind: "pack"}}, "Planned · not filed", "idle"},
          {%{sec: "plan", num: nil, id: "pack:example"}, "Planned · not filed", "idle"},
          {%{sec: "nq"}, "Not queued", "idle"}
        ] do
      assert TicketStatus.encode(row) == %{label: label, tone: tone, agent_state: nil}
    end
  end
end

defmodule Aiur.Orchestrator.RemoteControlModeTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.RemoteControlMode

  test "remote control summary requires both the alias label and session URL" do
    issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:remote"]}

    assert RemoteControlMode.remote_control_summary(%{issue: issue}) == nil

    assert RemoteControlMode.remote_control_summary(%{
             issue: %Issue{issue | labels: ["model:codex"]},
             repl_rc_session_url: "https://claude.ai/code/session_1"
           }) == nil

    assert RemoteControlMode.remote_control_summary(%{
             issue: issue,
             repl_rc_session_url: "https://claude.ai/code/session_1"
           }) == %{status: :on, session_url: "https://claude.ai/code/session_1"}
  end

  test "label helpers are idempotent" do
    issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:codex"]}

    assert RemoteControlMode.add_issue_label(issue, "MODEL:REMOTE").labels == ["model:codex", "model:remote"]

    assert RemoteControlMode.add_issue_label(
             RemoteControlMode.add_issue_label(issue, "model:remote"),
             "model:remote"
           ).labels == ["model:codex", "model:remote"]

    assert RemoteControlMode.remove_issue_label(issue, "model:remote") == issue

    assert RemoteControlMode.remove_issue_label(
             RemoteControlMode.add_issue_label(issue, "model:remote"),
             "model:remote"
           ).labels == ["model:codex"]
  end
end

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

  test "promotion preserves the live agent when redispatch is not ready" do
    issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:codex"]}
    entry = running_entry(issue)
    state = %Aiur.Orchestrator.State{running: %{issue.id => entry}}

    assert {{:error, :thrash_circuit_open}, ^state} =
             RemoteControlMode.set_remote_control_reply(state, issue.identifier, true,
               dashboard_url_fun: fn -> "http://localhost:4000" end,
               dispatch_ready_fun: fn _state, relabeled, nil ->
                 assert "model:remote" in relabeled.labels
                 {:error, :thrash_circuit_open}
               end
             )
  end

  test "demotion preserves the live agent when redispatch is not ready" do
    issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:remote"]}
    entry = running_entry(issue)
    state = %Aiur.Orchestrator.State{running: %{issue.id => entry}}

    assert {{:error, :thrash_circuit_open}, ^state} =
             RemoteControlMode.set_remote_control_reply(state, issue.identifier, false,
               dispatch_ready_fun: fn _state, relabeled, nil ->
                 refute "model:remote" in relabeled.labels
                 {:error, :thrash_circuit_open}
               end
             )
  end

  test "failed promotion redispatch does not leave the torn-down entry consuming a slot" do
    issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:codex"]}
    entry = running_entry(issue)
    state = %Aiur.Orchestrator.State{running: %{issue.id => entry}}

    assert {{:ok, :on}, next_state} =
             RemoteControlMode.set_remote_control_reply(state, issue.identifier, true,
               dashboard_url_fun: fn -> "http://localhost:4000" end,
               dispatch_ready_fun: fn admitted_state, _relabeled, nil ->
                 {:ok, admitted_state}
               end,
               trust_fun: fn _workspace, _opts -> :ok end,
               add_label_fun: fn _identifier, _label -> :ok end,
               teardown_fun: fn current_state, _running_entry -> current_state end,
               dispatch_fun: fn dispatch_state, _issue, nil, nil, _opts -> dispatch_state end
             )

    refute Map.has_key?(next_state.running, issue.id)
  end

  defp running_entry(issue) do
    %{
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/aiur-rc-test",
      worker_host: nil,
      pid: self(),
      ref: make_ref(),
      control: %{status: :working}
    }
  end
end

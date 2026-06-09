defmodule Aiur.OrchestratorRemoteControlTest do
  # Not async: shares the boot-time ETS tracked-set table and the live
  # Orchestrator; the promote/demote success paths re-dispatch through a
  # supervised AgentRunner task.
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.State

  @remote_label "model:claude-remote"

  defp running_entry(identifier, labels, overrides) do
    issue = %Issue{id: "issue-#{identifier}", identifier: identifier, labels: labels}

    base = %{
      pid: nil,
      ref: nil,
      identifier: identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: nil,
      started_at: DateTime.utc_now(),
      control: %{status: :working}
    }

    Map.merge(base, Map.new(overrides))
  end

  defp state_with(entries) do
    running = Map.new(entries, fn entry -> {entry.issue.id, entry} end)

    %State{
      running: running,
      claimed: MapSet.new(Map.keys(running)),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{},
      max_concurrent_agents: 6
    }
  end

  describe "promote (set on): gating before any label op" do
    test "a claude agent on a remote worker is unsupported in v1" do
      entry = running_entry("CLA-1", ["model:claude"], worker_host: "box-2", workspace_path: "/tmp/ws")
      state = state_with([entry])

      assert {{:error, :remote_unsupported}, ^state} =
               Orchestrator.set_remote_control_for_test(state, "CLA-1", true)
    end

    test "an agent with no workspace yet is unavailable" do
      entry = running_entry("CLA-2", ["model:claude"], workspace_path: nil)
      state = state_with([entry])

      assert {{:error, :workspace_unavailable}, ^state} =
               Orchestrator.set_remote_control_for_test(state, "CLA-2", true)
    end

    test "a codex agent with no workspace is unavailable (codex IS promotable once gates pass)" do
      entry = running_entry("CDX-1", ["model:codex"], workspace_path: nil)
      state = state_with([entry])

      assert {{:error, :workspace_unavailable}, ^state} =
               Orchestrator.set_remote_control_for_test(state, "CDX-1", true)
    end

    test "an identifier that is not running returns :not_running" do
      state = state_with([running_entry("CLA-3", ["model:claude"], workspace_path: "/tmp/ws")])

      assert {{:error, :not_running}, ^state} =
               Orchestrator.set_remote_control_for_test(state, "GHOST-9", true)
    end

    test "promoting an already-remote agent is an idempotent no-op" do
      entry = running_entry("REM-1", [@remote_label], workspace_path: "/tmp/ws")
      state = state_with([entry])

      assert {{:ok, :on}, ^state} =
               Orchestrator.set_remote_control_for_test(state, "REM-1", true)
    end
  end

  describe "demote (set off): gating before any label op" do
    test "demoting a non-remote agent is an idempotent no-op" do
      entry = running_entry("CLA-4", ["model:claude"], workspace_path: "/tmp/ws")
      state = state_with([entry])

      assert {{:ok, :off}, ^state} =
               Orchestrator.set_remote_control_for_test(state, "CLA-4", false)
    end

    test "an identifier that is not running returns :not_running" do
      state = state_with([running_entry("REM-2", [@remote_label], workspace_path: "/tmp/ws")])

      assert {{:error, :not_running}, ^state} =
               Orchestrator.set_remote_control_for_test(state, "GHOST-9", false)
    end
  end

  describe "label-op failure leaves the current agent intact" do
    # The default test tracker is Linear, whose add_label/remove_label return
    # {:error, :unsupported} — a stand-in for any tracker write failure.
    setup do
      claude_json = Path.join(System.tmp_dir!(), "rc-claude-#{System.unique_integer([:positive])}.json")
      Application.put_env(:aiur, :remote_control_claude_json, claude_json)

      on_exit(fn ->
        Application.delete_env(:aiur, :remote_control_claude_json)
        File.rm(claude_json)
      end)

      {:ok, claude_json: claude_json}
    end

    test "promote: a label-add failure aborts with the agent still running" do
      workspace = Path.join(System.tmp_dir!(), "rc-ws-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      agent_pid = spawn(fn -> Process.sleep(:infinity) end)
      agent_ref = Process.monitor(agent_pid)

      entry =
        running_entry("CLA-FAIL", ["model:claude"],
          pid: agent_pid,
          ref: agent_ref,
          workspace_path: workspace
        )

      state = state_with([entry])

      {result, new_state} =
        capture_and_return(fn ->
          Orchestrator.set_remote_control_for_test(state, "CLA-FAIL", true)
        end)

      assert {:error, {:rc_label_failed, :unsupported}} = result
      assert new_state == state
      assert Process.alive?(agent_pid)

      Process.exit(agent_pid, :kill)
      File.rm_rf(workspace)
    end
  end

  describe "promote / demote success (memory tracker captures the label op)" do
    setup do
      workspace = Path.join(System.tmp_dir!(), "rc-ws-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      claude_json = Path.join(System.tmp_dir!(), "rc-claude-#{System.unique_integer([:positive])}.json")

      Application.put_env(:aiur, :remote_control_claude_json, claude_json)
      write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:aiur, :memory_tracker_recipient, self())

      on_exit(fn ->
        Application.delete_env(:aiur, :remote_control_claude_json)
        File.rm(claude_json)
        File.rm_rf(workspace)
      end)

      {:ok, workspace: workspace}
    end

    test "promote a headless claude agent: adds the label, stops the agent, re-dispatches", %{workspace: workspace} do
      agent_pid = spawn(fn -> Process.sleep(:infinity) end)
      agent_ref = Process.monitor(agent_pid)

      entry =
        running_entry("CLA-P", ["model:claude"],
          pid: agent_pid,
          ref: agent_ref,
          workspace_path: workspace
        )

      state = state_with([entry])

      {result, _new_state} =
        capture_and_return(fn ->
          Orchestrator.set_remote_control_for_test(state, "CLA-P", true)
        end)

      assert result == {:ok, :on}
      assert_received {:memory_tracker_add_label, "CLA-P", @remote_label}

      # Old agent killed and its monitor flushed (no stray :DOWN re-dispatch).
      refute Process.alive?(agent_pid)
      refute_receive {:DOWN, ^agent_ref, :process, _, _}, 200
    end

    test "promote a codex agent re-dispatches it as claude-remote", %{workspace: workspace} do
      agent_pid = spawn(fn -> Process.sleep(:infinity) end)
      agent_ref = Process.monitor(agent_pid)

      entry =
        running_entry("CDX-P", ["model:codex"],
          pid: agent_pid,
          ref: agent_ref,
          workspace_path: workspace
        )

      state = state_with([entry])

      {result, _new_state} =
        capture_and_return(fn ->
          Orchestrator.set_remote_control_for_test(state, "CDX-P", true)
        end)

      assert result == {:ok, :on}
      assert_received {:memory_tracker_add_label, "CDX-P", @remote_label}
      refute Process.alive?(agent_pid)
    end

    test "demote a remote agent: removes the label, stops the agent, re-dispatches", %{workspace: workspace} do
      agent_pid = spawn(fn -> Process.sleep(:infinity) end)
      agent_ref = Process.monitor(agent_pid)

      entry =
        running_entry("REM-P", [@remote_label],
          pid: agent_pid,
          ref: agent_ref,
          workspace_path: workspace
        )

      state = state_with([entry])

      {result, _new_state} =
        capture_and_return(fn ->
          Orchestrator.set_remote_control_for_test(state, "REM-P", false)
        end)

      assert result == {:ok, :off}
      assert_received {:memory_tracker_remove_label, "REM-P", @remote_label}
      refute Process.alive?(agent_pid)
    end
  end

  describe "remote-control summary derives from the label" do
    test "an issue carrying the remote label reads as :on" do
      entry = running_entry("REM-S", [@remote_label], [])

      assert Orchestrator.remote_control_summary_for_test(entry) == %{status: :on, session_url: nil}
    end

    test "a labeled entry surfaces the captured REPL RC session URL" do
      url = "https://claude.ai/code/session_01LguPUDk5vT6Tt31FH2KUmG"
      entry = running_entry("REM-U", [@remote_label], repl_rc_session_url: url)

      assert Orchestrator.remote_control_summary_for_test(entry) == %{status: :on, session_url: url}
    end

    test "a non-remote issue reads as nil" do
      entry = running_entry("CLA-S", ["model:claude"], [])

      assert Orchestrator.remote_control_summary_for_test(entry) == nil
    end
  end

  # Run `fun` with logs captured (re-dispatch spins a supervised task that
  # logs as it boots), forwarding its return value out of the capture.
  defp capture_and_return(fun) do
    ExUnit.CaptureLog.capture_log(fn -> send(self(), {:ret, fun.()}) end)
    assert_received {:ret, ret}
    ret
  end
end

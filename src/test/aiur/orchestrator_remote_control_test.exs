defmodule Aiur.OrchestratorRemoteControlTest do
  # Not async: shares the boot-time ETS tracked-set table and the
  # Aiur.Claude.RemoteControl.Supervisor with the live Orchestrator.
  use Aiur.TestSupport

  alias Aiur.Claude.RemoteControl
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.State

  # A `printf` that emits the real RC URL line, then idles so the
  # server stays up — stands in for the `claude remote-control` spawn.
  @rc_url "https://claude.ai/code/session_01RCTEST"
  @rc_command "printf 'Continue coding in the Claude mobile app or #{@rc_url}\\n'; sleep 30"

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

  describe "set_remote_control on: capability gating (no spawn)" do
    test "a codex agent is unsupported" do
      entry = running_entry("CDX-1", ["model:codex"], workspace_path: "/tmp/ws")
      state = state_with([entry])

      assert {{:error, :unsupported}, ^state} =
               Orchestrator.set_remote_control_for_test(state, "CDX-1", true)
    end

    test "a claude agent on a remote worker is unsupported in v1" do
      entry = running_entry("CLA-1", ["model:claude"], worker_host: "box-2", workspace_path: "/tmp/ws")
      state = state_with([entry])

      assert {{:error, :remote_unsupported}, ^state} =
               Orchestrator.set_remote_control_for_test(state, "CLA-1", true)
    end

    test "a claude agent with no workspace yet is unavailable" do
      entry = running_entry("CLA-2", ["model:claude"], workspace_path: nil)
      state = state_with([entry])

      assert {{:error, :workspace_unavailable}, ^state} =
               Orchestrator.set_remote_control_for_test(state, "CLA-2", true)
    end

    test "an identifier that is not running returns :not_running" do
      state = state_with([running_entry("CLA-3", ["model:claude"], workspace_path: "/tmp/ws")])

      assert {{:error, :not_running}, ^state} =
               Orchestrator.set_remote_control_for_test(state, "GHOST-9", true)
    end

    test "toggling on an already-handed-off agent is an idempotent no-op" do
      entry =
        running_entry("CLA-4", ["model:claude"],
          workspace_path: "/tmp/ws",
          control: %{status: :deactivated},
          remote_control: %{status: :on, server_pid: self(), ref: make_ref(), session_url: @rc_url}
        )

      state = state_with([entry])

      assert {{:ok, :on}, ^state} =
               Orchestrator.set_remote_control_for_test(state, "CLA-4", true)
    end
  end

  describe "remote-control active entry guard" do
    test "active? is true while launching and on, false otherwise" do
      assert Orchestrator.remote_control_active_entry_for_test?(%{remote_control: %{status: :launching}})
      assert Orchestrator.remote_control_active_entry_for_test?(%{remote_control: %{status: :on}})
      refute Orchestrator.remote_control_active_entry_for_test?(%{remote_control: %{status: :failed}})
      refute Orchestrator.remote_control_active_entry_for_test?(%{})
    end

    test "summary surfaces status and url, or nil when absent" do
      assert Orchestrator.remote_control_summary_for_test(%{
               remote_control: %{status: :on, session_url: @rc_url}
             }) == %{status: :on, session_url: @rc_url}

      assert Orchestrator.remote_control_summary_for_test(%{}) == nil
    end

    test "reactivate refuses to restart a headless driver under a live RC session" do
      entry =
        running_entry("CLA-5", ["model:claude"],
          workspace_path: "/tmp/ws",
          control: %{status: :deactivated},
          remote_control: %{status: :on, server_pid: self(), ref: make_ref(), session_url: @rc_url}
        )

      state = state_with([entry])

      assert {{:error, :remote_control_active}, ^state} =
               Orchestrator.reactivate_issue_for_test(state, entry)
    end
  end

  describe "stall watchdog leaves RC-on entries alone" do
    test "a deactivated RC entry is not restarted even past the stall timeout" do
      entry =
        running_entry("CLA-6", ["model:claude"],
          workspace_path: "/tmp/ws",
          started_at: DateTime.add(DateTime.utc_now(), -3600, :second),
          control: %{status: :deactivated},
          remote_control: %{status: :on, server_pid: self(), ref: make_ref(), session_url: @rc_url}
        )

      state = state_with([entry])

      after_check = Orchestrator.apply_stall_check_for_test(state, 1)

      assert after_check.running["issue-CLA-6"][:remote_control][:status] == :on
      assert get_in(after_check.running["issue-CLA-6"], [:control, :status]) == :deactivated
      assert after_check.retry_attempts == %{}
    end
  end

  describe "launch lifecycle (real RC server, injected spawn command)" do
    setup do
      claude_json = Path.join(System.tmp_dir!(), "rc-claude-#{System.unique_integer([:positive])}.json")
      workspace = Path.join(System.tmp_dir!(), "rc-ws-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)

      Application.put_env(:aiur, :remote_control_command, @rc_command)
      Application.put_env(:aiur, :remote_control_claude_json, claude_json)

      on_exit(fn ->
        Application.delete_env(:aiur, :remote_control_command)
        Application.delete_env(:aiur, :remote_control_claude_json)
        File.rm(claude_json)
        File.rm_rf(workspace)
      end)

      {:ok, workspace: workspace, claude_json: claude_json}
    end

    defp launch!(workspace) do
      agent_pid = spawn(fn -> Process.sleep(:infinity) end)
      agent_ref = Process.monitor(agent_pid)

      entry =
        running_entry("CLA-RC", ["model:claude"],
          pid: agent_pid,
          ref: agent_ref,
          workspace_path: workspace
        )

      state = state_with([entry])
      {result, new_state} = Orchestrator.set_remote_control_for_test(state, "CLA-RC", true)
      {result, new_state, agent_pid, agent_ref}
    end

    test "set on stops the headless agent and brings up an RC server", %{workspace: workspace, claude_json: claude_json} do
      {result, state, agent_pid, agent_ref} = launch!(workspace)

      assert result == {:ok, :on}

      rc = state.running["issue-CLA-RC"][:remote_control]
      assert rc.status == :launching
      assert is_pid(rc.server_pid)
      assert Process.alive?(rc.server_pid)

      entry = state.running["issue-CLA-RC"]
      assert entry.pid == nil
      assert entry.ref == nil
      assert get_in(entry, [:control, :status]) == :deactivated

      # Headless driver was killed and its monitor flushed.
      refute Process.alive?(agent_pid)
      refute_receive {:DOWN, ^agent_ref, :process, _, _}, 200

      # Workspace was trust-seeded off the real ~/.claude.json.
      assert File.exists?(claude_json)
      assert File.exists?(Path.join(workspace, "CLAUDE.local.md"))

      # The owner (this test process) gets the parsed URL from stdout.
      assert_receive {:remote_control_url, server_pid, url}, 5_000
      assert server_pid == rc.server_pid
      assert url == @rc_url

      RemoteControl.stop(rc.server_pid)
    end

    test "the URL handler flips the entry to :on and records the session url", %{workspace: workspace} do
      {_result, state, _agent_pid, _agent_ref} = launch!(workspace)
      server_pid = state.running["issue-CLA-RC"][:remote_control].server_pid

      updated = Orchestrator.update_remote_control_url_for_test(state, server_pid, @rc_url)
      rc = updated.running["issue-CLA-RC"][:remote_control]

      assert rc.status == :on
      assert rc.session_url == @rc_url

      RemoteControl.stop(server_pid)
    end

    test "an RC server DOWN clears RC state but keeps the deactivated entry", %{workspace: workspace} do
      {_result, state, _agent_pid, _agent_ref} = launch!(workspace)
      server_pid = state.running["issue-CLA-RC"][:remote_control].server_pid
      RemoteControl.stop(server_pid)

      cleared = Orchestrator.drop_remote_control_for_server_for_test(state, server_pid)
      entry = cleared.running["issue-CLA-RC"]

      assert Map.has_key?(entry, :remote_control) == false
      assert get_in(entry, [:control, :status]) == :deactivated
    end

    test "set off stops the RC server and re-dispatches the agent", %{workspace: workspace} do
      {_result, state, _agent_pid, _agent_ref} = launch!(workspace)
      server_pid = state.running["issue-CLA-RC"][:remote_control].server_pid

      # The off path re-dispatches via a supervised AgentRunner task,
      # which logs as it spins up — swallow that noise.
      ExUnit.CaptureLog.capture_log(fn ->
        {result, _state} = Orchestrator.set_remote_control_for_test(state, "CLA-RC", false)
        send(self(), {:off_result, result})
      end)

      assert_received {:off_result, {:ok, :off}}
      refute Process.alive?(server_pid)
    end

    test "set off deletes the handoff file so the re-dispatched agent is clean", %{workspace: workspace} do
      {_result, state, _agent_pid, _agent_ref} = launch!(workspace)
      handoff = Path.join(workspace, "CLAUDE.local.md")
      assert File.exists?(handoff)

      ExUnit.CaptureLog.capture_log(fn ->
        Orchestrator.set_remote_control_for_test(state, "CLA-RC", false)
      end)

      refute File.exists?(handoff)
    end

    test "terminating an RC-active issue stops the server and clears the handoff", %{workspace: workspace} do
      {_result, state, _agent_pid, _agent_ref} = launch!(workspace)
      server_pid = state.running["issue-CLA-RC"][:remote_control].server_pid
      handoff = Path.join(workspace, "CLAUDE.local.md")
      assert File.exists?(handoff)

      ExUnit.CaptureLog.capture_log(fn ->
        new_state = Orchestrator.terminate_running_issue_for_test(state, "issue-CLA-RC", false)
        send(self(), {:terminated, new_state})
      end)

      assert_received {:terminated, new_state}
      refute Map.has_key?(new_state.running, "issue-CLA-RC")
      refute Process.alive?(server_pid)
      refute File.exists?(handoff)
    end

    test "a trust failure aborts the launch with the headless driver intact", %{workspace: workspace, claude_json: claude_json} do
      # Point the trust write at a path that can't be created (a file used as
      # a directory), so ensure_workspace_trusted returns {:error, _}.
      File.write!(claude_json, "{}")
      Application.put_env(:aiur, :remote_control_claude_json, Path.join(claude_json, "nested.json"))

      agent_pid = spawn(fn -> Process.sleep(:infinity) end)
      agent_ref = Process.monitor(agent_pid)

      entry =
        running_entry("CLA-RC", ["model:claude"],
          pid: agent_pid,
          ref: agent_ref,
          workspace_path: workspace
        )

      state = state_with([entry])

      {result, new_state} =
        ExUnit.CaptureLog.capture_log(fn ->
          send(self(), {:res, Orchestrator.set_remote_control_for_test(state, "CLA-RC", true)})
        end)
        |> then(fn _log ->
          assert_received {:res, res}
          res
        end)

      assert {:error, {:rc_trust_failed, _}} = result
      # State unchanged — driver still alive, no RC entry, no handoff written.
      assert new_state == state
      assert Process.alive?(agent_pid)
      refute File.exists?(Path.join(workspace, "CLAUDE.local.md"))

      Process.exit(agent_pid, :kill)
    end
  end
end

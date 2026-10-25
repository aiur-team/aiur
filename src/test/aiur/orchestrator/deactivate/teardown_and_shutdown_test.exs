defmodule Aiur.Orchestrator.Deactivate.TeardownAndShutdownTest do
  use Aiur.TestSupport

  alias Aiur.AgentResourceGuard
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.Reconciler

  @pgrep_skip_reason Aiur.TestSupport.pgrep_skip_reason()

  describe "REPL session teardown tracking (U7)" do
    test "{:repl_session_runtime, ...} records the pane id + os pid on the running entry" do
      issue_id = "issue-repl-track"
      identifier = "RPL-1"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :working},
            repl_pane_id: nil,
            repl_os_pid: nil
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      {:noreply, next} =
        Orchestrator.handle_info(
          {:repl_session_runtime, issue_id, %{pane_id: "%77", os_pid: 4242}},
          state
        )

      entry = next.running[issue_id]
      assert entry.repl_pane_id == "%77"
      assert entry.repl_os_pid == 4242
    end

    test "{:repl_session_runtime, ...} for an unknown issue is a no-op" do
      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      assert {:noreply, ^state} =
               Orchestrator.handle_info(
                 {:repl_session_runtime, "nope", %{pane_id: "%1", os_pid: 1}},
                 state
               )
    end

    test "deactivate tears down a tracked REPL session and still deactivates the entry" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-repl-teardown")

      issue_id = "issue-repl-teardown"
      issue_identifier = "RPT-1"

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        agent_pid =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: agent_pid,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "in-progress", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :working},
              # os pid nil keeps graceful_kill a no-op; the pane kill targets a
              # bogus id the real tmux server rejects harmlessly — the point is
              # the deactivate path's kill_repl_session runs cleanly.
              repl_pane_id: "%repl-bogus",
              repl_os_pid: nil
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "human-review",
          title: "PR up for review",
          description: "",
          labels: []
        }

        updated_state = Reconciler.reconcile_running_issue_states([issue], state)

        entry = Map.fetch!(updated_state.running, issue_id)
        assert get_in(entry, [:control, :status]) == :deactivated
        refute Process.alive?(agent_pid)
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "whole-app shutdown reaping (terminate/2)" do
    @tag skip: @pgrep_skip_reason
    test "reaps every running entry's headless agent subtree on shutdown" do
      # Mirror the headless backend: a `bash -lc` wrapper that forks a child
      # it never execs. On whole-app shutdown the supervisor brutally kills
      # the AgentRunner task (skipping `after stop_session`), so without a
      # terminate/2 reap the child reparents to init and keeps committing.
      command = "sleep 600 & printf 'up\\n'; wait"

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(System.find_executable("bash"))},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            line: 64_000
          ]
        )

      {:os_pid, bash_pid} = :erlang.port_info(port, :os_pid)

      receive do
        {^port, {:data, {:eol, "up"}}} -> :ok
      end

      child_pid = shutdown_child(bash_pid)

      on_exit(fn ->
        for p <- [bash_pid, child_pid], is_integer(p) do
          System.cmd("kill", ["-KILL", Integer.to_string(p)], stderr_to_stdout: true)
        end
      end)

      assert is_integer(child_pid)
      assert shutdown_os_alive?(child_pid)

      issue_id = "issue-shutdown-reap"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: "SHD-1",
            issue: %Issue{id: issue_id, state: "in-progress", identifier: "SHD-1"},
            started_at: DateTime.utc_now(),
            control: %{status: :working},
            headless_os_pid: bash_pid
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      assert :ok = Orchestrator.terminate(:shutdown, state)

      shutdown_wait_until_dead(bash_pid)
      shutdown_wait_until_dead(child_pid)
      refute shutdown_os_alive?(bash_pid)
      refute shutdown_os_alive?(child_pid)
    end

    defp shutdown_child(parent) do
      # The shell prints "up" only after spawning the child, so the port line
      # received above is the causal barrier for this descendant snapshot.
      parent
      |> AgentResourceGuard.collect_descendants()
      |> List.first()
    end

    defp shutdown_os_alive?(pid) do
      case File.read("/proc/#{pid}/stat") do
        {:ok, stat} -> not Regex.match?(~r/\)\s+Z(?:\s|$)/, stat)
        {:error, :enoent} -> false
        {:error, _reason} -> true
      end
    end

    defp shutdown_wait_until_dead(pid) do
      # A pidfd becomes readable when its process exits, including while the
      # exited process is briefly a zombie awaiting its parent. select/3 has no
      # deadline here: kernel readiness is the causal barrier.
      python = System.find_executable("python3") || flunk("python3 is required for pidfd exit barrier")

      script = ~S"""
      import os
      import select
      import sys

      try:
          fd = os.pidfd_open(int(sys.argv[1]))
      except ProcessLookupError:
          raise SystemExit(0)

      select.select([fd], [], [])
      """

      {_output, 0} =
        System.cmd(python, ["-c", script, Integer.to_string(pid)], stderr_to_stdout: true)

      :ok
    end
  end
end

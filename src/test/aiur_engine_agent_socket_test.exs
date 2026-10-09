defmodule AiurEngineAgentSocketTest do
  use ExUnit.Case, async: true
  @engine Path.expand("../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)

  test "reap tears down daemon and agent servers without touching a sibling" do
    socket = "aiur-reap-unit-#{System.unique_integer([:positive])}"
    names = [socket, socket <> "-agents", socket <> "-sibling"]
    for name <- names, do: assert({_, 0} = System.cmd("tmux", ["-L", name, "new-session", "-d", "-s", "test", "sleep 120"]))

    pids =
      Enum.map(Enum.take(names, 2), fn name ->
        {pid, 0} = System.cmd("tmux", ["-L", name, "display-message", "-p", "-t", "test", "\#{pane_pid}"])
        pid |> String.trim() |> String.to_integer()
      end)

    on_exit(fn ->
      for name <- names, do: System.cmd("tmux", ["-L", name, "kill-server"], stderr_to_stdout: true)
    end)

    assert {_, 0} =
             System.cmd(
               "bash",
               [
                 "-c",
                 ~S"""
                 source "$1"
                 unset AIUR_AGENT_TMUX_SOCKET
                 reap_aiur_agents "$2" ""
                 """,
                 "--",
                 @engine,
                 socket
               ],
               stderr_to_stdout: true
             )

    for name <- Enum.take(names, 2) do
      {_, status} = System.cmd("tmux", ["-L", name, "has-session"], stderr_to_stdout: true)
      assert status != 0
    end

    assert {_, 0} = System.cmd("tmux", ["-L", List.last(names), "has-session"])
    assert Enum.all?(pids, &process_stopped?/1)
  end

  test "BEAM-death watchdog removes both servers after its observed process is killed" do
    socket = "aiur-watch-unit-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      for name <- [socket, socket <> "-agents"], do: System.cmd("tmux", ["-L", name, "kill-server"], stderr_to_stdout: true)
    end)

    assert {output, 0} =
             System.cmd(
               "bash",
               [
                 "-c",
                 ~S"""
                 source "$1"
                 unset AIUR_AGENT_TMUX_SOCKET
                 socket="$2"
                 tmux -L "$socket" new-session -d -s daemon 'sleep 120'
                 tmux -L "$socket-agents" new-session -d -s repl 'sleep 120'
                 daemon_pid=$(tmux -L "$socket" display-message -p -t daemon '#{pane_pid}')
                 agent_pid=$(tmux -L "$socket-agents" display-message -p -t repl '#{pane_pid}')
                 bash -c 'exec -a "$1" sleep 120' -- "$socket-beam" &
                 beam=$!
                 watchdog=$(start_beam_death_watchdog "^$socket-beam " "$socket" "" 0.02 1)
                 kill -KILL "$beam"
                 wait "$beam" 2>/dev/null || true
                 for ((i=0; i<250; i++)); do
                   if ! tmux -L "$socket" has-session 2>/dev/null && ! tmux -L "$socket-agents" has-session 2>/dev/null; then
                     daemon_state=$(ps -o stat= -p "$daemon_pid" | tr -d ' ')
                     agent_state=$(ps -o stat= -p "$agent_pid" | tr -d ' ')
                     [[ -z "$daemon_state" || "$daemon_state" == Z* ]] || { sleep 0.02; continue; }
                     [[ -z "$agent_state" || "$agent_state" == Z* ]] || { sleep 0.02; continue; }
                     echo reaped
                     exit 0
                   fi
                   sleep 0.02
                 done
                 kill "$watchdog" 2>/dev/null || true
                 exit 1
                 """,
                 "--",
                 @engine,
                 socket
               ],
               stderr_to_stdout: true
             )

    assert output =~ "reaped\n"
  end

  defp process_stopped?(pid, attempts \\ 100)
  defp process_stopped?(_pid, 0), do: false

  defp process_stopped?(pid, attempts) do
    {state, _} = System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)])

    if String.trim(state) == "" or String.starts_with?(String.trim(state), "Z"),
      do: true,
      else:
        (
          Process.sleep(20)
          process_stopped?(pid, attempts - 1)
        )
  end

  test "stop uses recorded agent socket and falls back for legacy records" do
    root = Aiur.TestSupport.tmp_root!("stop-agent-socket")
    File.mkdir_p!(Path.join(root, "bin"))
    File.write!(Path.join(root, "bin/tmux"), "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$EVENTS\"\nexit 0\n")
    File.chmod!(Path.join(root, "bin/tmux"), 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {_, 0} =
             System.cmd(
               "bash",
               [
                 "-c",
                 ~S"""
                 source "$AIUR_ENGINE"
                 resolve_release() { :; }
                 aiur_resolve_identity() { :; }
                 resolve_control_identity_from_records() { :; }
                 kill_beams_matching() { :; }
                 reap_workspace_cwd_from_file() { :; }
                 reap_stale_manual_smoke() { :; }
                 sweep_dead_tmux_sockets() { :; }
                 sweep_stale_tmp_artifacts() { :; }
                 AIUR_INSTANCE_KEY=test
                 AIUR_RELEASE_NODE=aiur-test@127.0.0.1
                 AIUR_PROJECT_ROOT="$ROOT"
                 AIUR_PROJECT_ROOT_SOURCE=env
                 AIUR_ADOPTED_TMUX_SOCKET=aiur-test
                 AIUR_ADOPTED_TMUX_SESSION=aiur-test-default
                 AIUR_AGENT_TMUX_SOCKET=recorded-agents
                 write_aiur_instance_record aiur-test-default aiur-test
                 unset AIUR_AGENT_TMUX_SOCKET
                 cmd_stop
                 write_aiur_instance_record aiur-test-default aiur-test
                 sed '/AIUR_RECORD_AGENT_SOCKET=/d' "$(aiur_instance_record_path)" > "$ROOT/legacy"
                 mv "$ROOT/legacy" "$(aiur_instance_record_path)"
                 cmd_stop
                 """
               ],
               env: [{"AIUR_ENGINE", @engine}, {"AIUR_BG_STATE_DIR", root}, {"ROOT", root}, {"EVENTS", Path.join(root, "events")}, {"PATH", Path.join(root, "bin") <> ":" <> System.get_env("PATH")}],
               stderr_to_stdout: true
             )

    calls = File.read!(Path.join(root, "events"))
    assert calls =~ "-L aiur-test kill-server\n"
    assert calls =~ "-L recorded-agents kill-server\n"
    assert calls =~ "-L aiur-test-agents kill-server\n"
  end
end

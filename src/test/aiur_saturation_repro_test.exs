defmodule AiurSaturationReproTest do
  # Tests for scripts/aiur-saturation-repro.sh — the operator-run, bounded
  # controlled load reproduction for the #852 daemon saturation crash. The
  # script is structured so the pure helpers can be sourced without touching a
  # live daemon; the main body is guarded behind a BASH_SOURCE check.
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/aiur-saturation-repro.sh", __DIR__)

  # Source the script (no main body runs on source) and run `body` inside the
  # same bash, printing a sentinel so we can assert on captured output.
  defp sourced(body) do
    src = "set -euo pipefail\nsource \"#{@script}\"\n#{body}\necho SENTINEL_OK\n"
    {out, 0} = System.cmd("bash", ["-c", src], stderr_to_stdout: true)
    assert out =~ "SENTINEL_OK"
    out
  end

  test "float_gt compares non-integer load values numerically" do
    out = sourced("float_gt 3.5 2.0 && echo GT_OK || echo GT_BAD")
    assert out =~ "GT_OK"

    out = sourced("float_gt 2.0 3.5 && echo GT_BAD || echo LT_OK")
    assert out =~ "LT_OK"
  end

  test "resolve_dump_path honors an explicit override then the logs root" do
    out =
      sourced("""
      dump_path=/tmp/aiur-override.dump
      resolve_dump_path
      dump_path=""
      AIUR_LOGS_ROOT=/tmp/aiur-logs-root
      resolve_dump_path
      """)

    assert out =~ "/tmp/aiur-override.dump"
    assert out =~ "/tmp/aiur-logs-root/erl_crash.dump"
  end

  test "default_external_burn emits an uncapped scheduler-count CPU burn" do
    out = sourced("default_external_burn")
    # One busy process per online scheduler — the unmanaged-BEAM repro profile.
    assert out =~ "System.schedulers_online()"
    assert out =~ "spin.(spin, 0)"
    assert out =~ "Process.sleep(:infinity)"
  end

  test "running_agent_count prefers the authoritative AGENTS capacity line" do
    # Stub the aiur CLI: `aiur status` prints the capacity line; the function
    # must report the occupied count (7), not the table rows.
    out =
      sourced("""
      aiur_bin=stub_aiur
      stub_aiur() { echo "ISSUE STATE TITLE"; echo "#123 running do-the-thing"; echo "AGENTS 7/20 (binding: config max_concurrent_agents)"; }
      running_agent_count
      """)

    assert out =~ "7"
    refute out =~ "1"
  end

  test "main refuses invalid or oversized external beam counts and shows help" do
    {out, 2} = System.cmd("bash", [@script, "--external", "0"], stderr_to_stdout: true)
    assert out =~ "external_beams must be a positive integer"

    {out, 2} = System.cmd("bash", [@script, "--external", "9"], stderr_to_stdout: true)
    assert out =~ "exceeds the internal cap"

    {out, 0} = System.cmd("bash", [@script, "--help"], stderr_to_stdout: true)
    assert out =~ "Bounded, operator-run reproduction"
  end

  # --- daemon_state: the crash-detection primitive -------------------------
  #
  # The probe must use ONE `AIUR_BIN` value for every call it makes. `aiur` (the
  # CLI) has `status` and `__identity` but no `rpc`; the raw release bin has
  # `rpc` but no `status`. These stubs answer only the real CLI surface, so a
  # regression back to `aiur rpc` fails here instead of silently returning
  # "down" forever and skipping the entire repro.

  # Build a fake `aiur` CLI + a fake `epmd` on PATH, in a temp dir.
  defp stub_env(status_rc, epmd_names) do
    dir = Path.join(System.tmp_dir!(), "aiur-repro-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit_dir = dir

    File.write!(Path.join(dir, "aiur"), """
    #!/usr/bin/env bash
    case "${1:-}" in
      status) exit #{status_rc} ;;
      __identity)
        echo "AIUR_RELEASE_DIR=#{dir}"
        echo "AIUR_RELEASE_NODE=aiur-tester@127.0.0.1"
        ;;
      *) echo "aiur: unknown command: ${1:-}" >&2; exit 64 ;;
    esac
    """)

    File.write!(Path.join(dir, "epmd"), """
    #!/usr/bin/env bash
    #{if epmd_names == :unreachable, do: "exit 1", else: "cat <<'EOF'\n#{epmd_names}\nEOF"}
    """)

    File.chmod!(Path.join(dir, "aiur"), 0o755)
    File.chmod!(Path.join(dir, "epmd"), 0o755)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(on_exit_dir) end)
    dir
  end

  defp daemon_state(status_rc, epmd_names) do
    dir = stub_env(status_rc, epmd_names)

    sourced("""
    PATH="#{dir}:$PATH"
    aiur_bin="#{dir}/aiur"
    daemon_state
    echo
    """)
  end

  @registered "epmd: up and running on port 4369 with data:\nname aiur-tester at port 39001"
  @empty "epmd: up and running on port 4369 with data:"

  test "daemon_state reports up when the aiur CLI status probe succeeds" do
    assert daemon_state(0, @registered) =~ "up"
  end

  test "daemon_state reports saturated when status fails but epmd still lists the node" do
    # The engine documents that a scheduler-saturated but ALIVE daemon times out
    # control RPC. That must never be classified as a crash.
    out = daemon_state(124, @registered)
    assert out =~ "saturated"
    refute out =~ "down"
  end

  test "daemon_state reports down only when status fails and epmd has dropped the node" do
    assert daemon_state(1, @empty) =~ "down"
  end

  test "daemon_state reports unknown when epmd cannot be queried" do
    out = daemon_state(1, :unreachable)
    assert out =~ "unknown"
    refute out =~ "down"
  end

  test "daemon_state never invokes a non-existent `rpc` subcommand" do
    # The stub CLI mirrors the real engine: `rpc` is an unknown command. If the
    # probe regresses to `aiur rpc`, its usage error surfaces here.
    dir = stub_env(0, @registered)
    out = sourced(~s|aiur_bin="#{dir}/aiur"\ndaemon_state\necho|)
    refute out =~ "unknown command"
  end

  # --- watch_window: crash classification over the window -------------------

  defp watch(stub_daemon_state, dump_setup \\ "") do
    dir = Path.join(System.tmp_dir!(), "aiur-repro-watch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)

    sourced("""
    resolved_dump="#{dir}/erl_crash.dump"
    #{dump_setup}
    daemon_state() { printf '%s' "#{stub_daemon_state}"; }
    sleep() { :; }
    now=$(date +%s)
    watch_window "$now" $((now + 12)) >/dev/null
    echo "crashed=$crashed dump_seen=$dump_seen"
    """)
  end

  test "watch_window does not call a saturated daemon a crash" do
    # This is the false-positive the whole classifier exists to prevent: under
    # the target load profile the daemon stops answering control RPC while very
    # much alive, and the old any-probe-failure logic reported REPRODUCED.
    assert watch("saturated") =~ "crashed=0 dump_seen=0"
  end

  test "watch_window does not call an unclassifiable daemon a crash" do
    assert watch("unknown") =~ "crashed=0 dump_seen=0"
  end

  test "watch_window completes a clean window without crashing" do
    assert watch("up") =~ "crashed=0 dump_seen=0"
  end

  test "watch_window flags a crash with a dump when a fresh dump appears" do
    out = watch("up", ~s|touch "$resolved_dump"|)
    assert out =~ "crashed=1 dump_seen=1"
  end

  test "watch_window flags a crash without a dump when epmd drops the node" do
    # A real BEAM death, but no dump — reported distinctly (exit 4), never as a
    # confirmed reproduction of the #852 signature.
    assert watch("down") =~ "crashed=1 dump_seen=0"
  end

  test "watch_window ignores a stale pre-window dump" do
    # A dump left over from an earlier crash must not be read as this run's.
    out = watch("up", ~s|touch -d '2 hours ago' "$resolved_dump"|)
    assert out =~ "crashed=0 dump_seen=0"
  end

  test "script header documents the operator-only safety boundary" do
    # The whole point of the tool is load stacking; the guard must be visible
    # so it is never run by an agent or on the shared host.
    assert File.read!(@script) =~ "must NOT be run from inside an agent workspace"
    assert File.read!(@script) =~ "OPERATOR ONLY"
  end
end

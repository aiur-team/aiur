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

  test "script header documents the operator-only safety boundary" do
    # The whole point of the tool is load stacking; the guard must be visible
    # so it is never run by an agent or on the shared host.
    assert File.read!(@script) =~ "must NOT be run from inside an agent workspace"
    assert File.read!(@script) =~ "OPERATOR ONLY"
  end
end

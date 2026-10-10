defmodule AiurEngineRestartTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  # `restart` is the one command whose whole value is an ordering: the release
  # must be refreshed while the daemon is down. These stub the stop, the build,
  # and the start so the sequence is asserted without touching a real daemon.
  defp run_restart(args, opts) do
    stop = Keyword.get(opts, :stop, "echo STOP")
    env = Keyword.get(opts, :env, [])

    # The dev shim declares AIUR_RESTART_BUILD_VERIFIES whenever it wires in a
    # rebuild, so the verifying path is the default here too; the unverified
    # branch is exercised by its own test.
    env =
      if List.keymember?(env, "AIUR_RESTART_BUILD_CMD", 0) and
           not List.keymember?(env, "AIUR_RESTART_BUILD_VERIFIES", 0) do
        [{"AIUR_RESTART_BUILD_VERIFIES", "1"} | env]
      else
        env
      end

    run_sourced_engine(
      """
      cmd_stop() { #{stop}; }
      dispatch_run() { echo "RUN: $*"; }
      cmd_restart #{args}
      """,
      env
    )
  end

  # A stand-in for the dev shim's rebuild: it stamps the release and leaves the
  # receipt the engine checks, which is what makes an "it built" claim provable
  # rather than assumed. Tests that want the unverifiable cases distort exactly
  # one of the three facts.
  defp fake_build_cmd(release_dir, opts \\ []) do
    sha = Keyword.get(opts, :sha, "cafebabe")
    stamped_sha = Keyword.get(opts, :stamped_sha, sha)
    receipt_dir = Keyword.get(opts, :receipt_dir, release_dir)
    stamp = Keyword.get(opts, :stamp, true)
    dirty = Keyword.get(opts, :dirty, "no")

    stamp_step =
      if stamp do
        ~s|printf 'repo_root=/fake\\nsource_sha=#{stamped_sha}\\ndirty=#{dirty}\\n' > "#{release_dir}/AIUR_BUILD_STAMP"; |
      else
        ""
      end

    "echo BUILD; " <>
      stamp_step <>
      ~s|printf 'release_dir=#{receipt_dir}\\nrepo_root=/fake\\nsource_sha=#{sha}\\n' > "$AIUR_RESTART_BUILD_RECEIPT"|
  end

  test "restart stops, refreshes the release, then starts detached — in that order" do
    rel = fake_release()

    {out, 0} =
      run_restart("",
        env: [{"AIUR_RESTART_BUILD_CMD", fake_build_cmd(rel)}, {"AIUR_RELEASE_DIR", rel}]
      )

    markers =
      ~r/^(STOP|BUILD|RUN: .*)$/m
      |> Regex.scan(out)
      |> Enum.map(&List.last/1)

    assert markers == ["STOP", "BUILD", "RUN: --bg"]
  end

  test "restart refuses a legacy config before stopping or rebuilding" do
    root = Aiur.TestSupport.tmp_root!("aiur-restart-legacy-config")
    File.mkdir_p!(root)
    File.write!(Path.join(root, ".aiurconfig"), "tracker:\n  kind: memory\n")
    on_exit(fn -> File.rm_rf!(root) end)

    {out, code} =
      run_restart("",
        env: [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_RESTART_BUILD_CMD", "echo BUILD"}
        ]
      )

    assert code == 1
    assert out =~ ".aiurconfig is no longer supported"
    assert out =~ "relative prompt_file and hooks_file paths"
    refute out =~ "STOP"
    refute out =~ "BUILD"
    refute out =~ "RUN:"
  end

  test "restart confirms the release it is about to boot is the one just built" do
    # The command's whole promise is that a bounce cannot ship a stale release.
    # A rebuild that exits 0 does not establish that on its own, so the claim is
    # checked against the release on disk and reported.
    rel = fake_release()

    {out, 0} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", fake_build_cmd(rel, sha: "abc123")},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert out =~ "verified release #{rel} built from abc123"
    assert out =~ "RUN: --bg"
  end

  test "restart refuses to start when the rebuild leaves no receipt" do
    rel = fake_release()

    {out, code} =
      run_restart("",
        env: [{"AIUR_RESTART_BUILD_CMD", "echo BUILD"}, {"AIUR_RELEASE_DIR", rel}]
      )

    assert code == 70
    refute out =~ "RUN:"
    assert out =~ "left no build receipt"
    assert out =~ "could not be verified"
    assert out =~ "STOPPED and was NOT restarted"
  end

  test "restart refuses to start when the rebuild targeted a different release" do
    # The defect this exists for: a globally symlinked wrapper rebuilds one
    # checkout while the daemon boots from another, and every step exits 0.
    rel = fake_release()
    other = fake_release()

    {out, code} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", fake_build_cmd(rel, receipt_dir: other)},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert code == 70
    refute out =~ "RUN:"
    assert out =~ "targeted a different release"
    assert out =~ "rebuilt : #{other}"
    assert out =~ "booting : #{rel}"
  end

  test "restart refuses to start when the release carries no build stamp" do
    rel = fake_release()

    {out, code} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", fake_build_cmd(rel, stamp: false)},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert code == 70
    refute out =~ "RUN:"
    assert out =~ "carries no build stamp"
  end

  test "restart refuses to start when the release on disk is from another commit" do
    # A concurrent build landing between the rebuild and the start would leave a
    # release nobody vouched for; the stamp catches that the boot target moved.
    rel = fake_release()

    {out, code} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", fake_build_cmd(rel, sha: "abc123", stamped_sha: "def456")},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert code == 70
    refute out =~ "RUN:"
    assert out =~ "not built from the commit the rebuild reported"
    assert out =~ "rebuild reported : abc123"
    assert out =~ "release stamped  : def456"
  end

  test "a builder that promises no receipt is reported unverified, not stopped" do
    # AIUR_RESTART_BUILD_CMD is a documented generic hook. Holding a wrapper that
    # never promised a receipt to the receipt contract would turn an upgrade into
    # a stopped fleet; saying the guarantee did not apply is the honest answer.
    rel = fake_release()

    {out, 0} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", "echo BUILD"},
          {"AIUR_RESTART_BUILD_VERIFIES", nil},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert out =~ "UNVERIFIED rebuild"
    assert out =~ "RUN: --bg"
    refute out =~ "STOPPED"
  end

  test "restart refuses to start when the receipt is missing its fields" do
    rel = fake_release()

    {out, code} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", ~s|echo BUILD; printf 'repo_root=/fake\\n' > "$AIUR_RESTART_BUILD_RECEIPT"|},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert code == 70
    refute out =~ "RUN:"
    assert out =~ "receipt is malformed"
  end

  test "an unverifiable abort names the builder it could not confirm" do
    # Without this, an inherited AIUR_RESTART_BUILD_CMD from another checkout
    # produces an identical refusal on every retry with nothing to act on.
    rel = fake_release()

    {out, 70} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", "echo BUILD"},
          {"AIUR_RESTART_BUILD_VERIFIES", "1"},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert out =~ "rebuild command: echo BUILD"
  end

  test "restart declines to claim a verified boot for a release it cannot identify" do
    rel = fake_release()

    {out, 0} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", fake_build_cmd(rel, sha: "unknown")},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert out =~ "source commit is"
    assert out =~ "provenance unverified"
    refute out =~ "verified release"
    assert out =~ "RUN: --bg"
  end

  test "restart says so when the release was built from a dirty tree" do
    rel = fake_release()

    {out, 0} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", fake_build_cmd(rel, sha: "abc123", dirty: "yes")},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert out =~ "built from abc123 with uncommitted changes"
    refute out =~ "verified release"
    assert out =~ "RUN: --bg"
  end

  test "restart forwards run flags but consumes --no-build, which skips the refresh" do
    {out, 0} =
      run_restart("--no-build --interactive --port 4099",
        env: [{"AIUR_RESTART_BUILD_CMD", "echo BUILD"}]
      )

    refute out =~ "BUILD"
    assert out =~ "restarting on the release already on disk"
    assert out =~ "RUN: --bg --interactive --port 4099"
  end

  test "a failed refresh aborts before the start, keeps the builder's exit code, and names the state" do
    # The failure mode this command exists to prevent is a silent one: never
    # start on a stale release, and never leave the operator thinking a daemon
    # they can no longer see is still up.
    rel = fake_release()

    {out, code} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", "echo BOOM >&2; exit 3"},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert code == 3
    refute out =~ "RUN:"
    assert out =~ "STOPPED and was NOT restarted"
    # The release survived this build, so the fast-bounce escape hatch is real.
    assert out =~ "aiur restart --no-build"
  end

  test "a failed refresh that destroyed the release does not advertise --no-build" do
    # The dev builder deletes an incomplete release. Offering `--no-build` then
    # would send the operator into a second failed cycle with the fleet down.
    {out, code} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", "exit 9"},
          {"AIUR_RELEASE_DIR", Path.join(System.tmp_dir!(), "aiur-engine-no-such-release")}
        ]
      )

    assert code == 9
    assert out =~ "STOPPED and was NOT restarted"
    assert out =~ "no complete release is left on disk"
    refute out =~ "restart --no-build"
  end

  test "a start that fails after the stop still reports the stopped fleet" do
    # Every failure after the stop — not just the rebuild — must say the daemon
    # is down, or "failed to start" reads as "nothing changed".
    {out, code} =
      run_sourced_engine(
        """
        cmd_stop() { echo STOP; }
        dispatch_run() { echo "start blew up" >&2; exit 1; }
        cmd_restart
        """,
        [{"AIUR_RESTART_BUILD_CMD", nil}]
      )

    assert code == 1
    assert out =~ "STOPPED and was NOT restarted"
  end

  test "a completed restart says nothing about a stopped daemon" do
    rel = fake_release()

    {out, 0} =
      run_restart("",
        env: [{"AIUR_RESTART_BUILD_CMD", fake_build_cmd(rel)}, {"AIUR_RELEASE_DIR", rel}]
      )

    refute out =~ "STOPPED"
  end

  test "restart refuses to build or start when the stop itself failed" do
    # Only "nothing was running" is tolerable. Any other stop failure may have
    # left the BEAM alive, and rebuilding under it is the hazard the ordering
    # exists to avoid.
    {out, code} =
      run_restart("",
        stop: "echo 'stop exploded' >&2; return 7",
        env: [{"AIUR_RESTART_BUILD_CMD", "echo BUILD"}]
      )

    assert code == 1
    refute out =~ "BUILD"
    refute out =~ "RUN:"
    assert out =~ "stop failed (exit 7)"
  end

  test "restart with no build command wired in is a plain bounce" do
    # The installed CLI runs a pinned platform release: there is nothing to
    # build, so restart must still stop and start rather than fail.
    {out, 0} = run_restart("", env: [{"AIUR_RESTART_BUILD_CMD", nil}])

    assert out =~ "STOP"
    assert out =~ "RUN: --bg"
  end

  test "restart starts a fresh session when nothing was running" do
    rel = fake_release()

    {out, 0} =
      run_restart("",
        stop: "AIUR_STOP_FOUND_NOTHING=1; return 1",
        env: [{"AIUR_RESTART_BUILD_CMD", fake_build_cmd(rel)}, {"AIUR_RELEASE_DIR", rel}]
      )

    assert out =~ "nothing was running"
    assert out =~ "BUILD"
    assert out =~ "RUN: --bg"
  end

  test "restart refuses to rebuild or start when the stopped session still answers" do
    # cmd_stop's tmux teardown is best-effort, so a "successful" stop can leave
    # the daemon alive. Rebuilding then would rewrite the release under a live
    # BEAM, and the start would no-op into "already running" with exit 0.
    {out, code} =
      run_sourced_engine(
        """
        cmd_stop() { release_bin=/nonexistent-release-bin; echo STOP; }
        probe_control_liveness() { printf up; }
        dispatch_run() { echo "RUN: $*"; }
        cmd_restart
        """,
        [{"AIUR_RESTART_BUILD_CMD", "echo BUILD"}]
      )

    assert code == 1
    refute out =~ "BUILD"
    refute out =~ "RUN:"
    assert out =~ "still answers after the stop"
  end

  test "the restart dispatch arm drops the subcommand and forwards the rest" do
    {out, 0} =
      run_sourced_engine(
        """
        cmd_restart() { echo "RESTART: $*"; }
        aiur_engine_main restart --no-build --interactive
        """,
        []
      )

    assert out =~ "RESTART: --no-build --interactive"
  end

  test "usage advertises restart" do
    {out, 0} = run_sourced_engine("usage", [])

    assert out =~ "aiur restart"
    assert out =~ "--no-build"
  end

  # --- aiur upgrade + the aiur run version notice (#2109) --------------------
end

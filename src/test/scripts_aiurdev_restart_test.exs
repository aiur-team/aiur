defmodule ScriptsAiurdevRestartTest do
  # async: false — see ScriptsAiurdevTest (File.cd! is process-global, #589).
  use ExUnit.Case, async: false

  import Aiur.TestSupport.AiurdevCase

  @script Aiur.TestSupport.AiurdevCase.script()

  test "restart hands the engine a rebuild command instead of rebuilding first" do
    # The engine runs this command between its stop and its start. Rebuilding
    # here instead would rewrite the release under the still-live BEAM — the
    # exact ordering `restart` exists to avoid — so a stale tree must reach the
    # engine unbuilt, with only a complete-enough release to issue the stop.
    root = fake_repo()
    mise = fake_mise()
    log = Path.join(root, "release.log")

    seed_ready_release(root)
    File.mkdir_p!(Path.join([root, "src", "lib"]))
    newer = Path.join([root, "src", "lib", "newer.ex"])
    File.write!(newer, "# stale after release\n")
    File.touch!(Path.join([root, "src", "bin", "aiur"]), {{2020, 1, 1}, {0, 0, 0}})
    File.touch!(newer, {{2030, 1, 1}, {0, 0, 0}})

    {out, 0} =
      run_shim(["restart"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_FAKE_MISE_RELEASE_LOG", log},
        {"TMUX", nil}
      ])

    assert out =~ "ENGINE_ARGS: restart"

    # The repo root is pinned into the command, not left to the child to
    # re-derive from its own path in a process the engine launches from the
    # operator's cwd — by the stop, the target is already settled.
    assert out =~ ~r/RESTART_BUILD_CMD: AIUR_REPO_ROOT=\S*\s+\S*aiurdev __ensure-build/
    assert out =~ "AIUR_REPO_ROOT=#{root}"
    refute out =~ "rebuilding"
    refute File.exists?(log), "restart must not rebuild before the engine stops the daemon"

    # The flag has to survive the shim's own passthrough parsing to reach the
    # engine, and it must not change which pre-dispatch path restart takes.
    {no_build_out, 0} =
      run_shim(["restart", "--no-build"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_FAKE_MISE_RELEASE_LOG", log},
        {"TMUX", nil}
      ])

    assert no_build_out =~ "ENGINE_ARGS: restart --no-build"
    refute File.exists?(log)
  end

  test "the rebuild command the shim emits actually runs, from a path with a space" do
    # Both suites otherwise stub the opposite side of this seam. Run the exact
    # string the engine would run, so a broken path hop, a lost `__ensure-build`
    # argument, or unquoted whitespace fails here instead of in production —
    # after the daemon has already been stopped.
    root = fake_repo()
    mise = fake_mise()
    log = Path.join(root, "release.log")

    shim_dir = Aiur.TestSupport.tmp_root!("aiur dev shim")
    File.mkdir_p!(shim_dir)
    shim = Path.join(shim_dir, "aiurdev")
    File.cp!(@script, shim)
    copy_shim_libs!(Path.dirname(shim))
    File.chmod!(shim, 0o755)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(shim_dir) end)

    seed_ready_release(root)
    File.mkdir_p!(Path.join([root, "src", "lib"]))
    newer = Path.join([root, "src", "lib", "newer.ex"])
    File.write!(newer, "# stale after release\n")
    File.touch!(Path.join([root, "src", "bin", "aiur"]), {{2020, 1, 1}, {0, 0, 0}})
    File.touch!(newer, {{2030, 1, 1}, {0, 0, 0}})

    env = [
      {"AIUR_REPO_ROOT", root},
      {"AIUR_MISE_BIN", mise},
      {"AIUR_FAKE_MISE_RELEASE_LOG", log},
      {"TMUX", nil}
    ]

    {out, 0} = System.cmd("bash", [shim, "restart"], env: env, stderr_to_stdout: true)

    [_, build_cmd] = Regex.run(~r/RESTART_BUILD_CMD: (.+)/, out)
    assert build_cmd =~ "__ensure-build"

    # Exactly how the engine invokes it, receipt and all.
    receipt = Path.join(root, "receipt")

    {build_out, 0} =
      System.cmd("bash", ["-c", build_cmd],
        env: [{"AIUR_RESTART_BUILD_RECEIPT", receipt} | env],
        stderr_to_stdout: true
      )

    assert build_out =~ "the daemon is stopped until this finishes"
    assert build_out =~ "rebuilding"
    assert File.exists?(log)
    assert File.read!(receipt) =~ "release_dir=#{root}/src/_build/dev/rel/aiur"
  end

  test "the rebuild command is exported only for restart" do
    # Otherwise the daemon and every agent it spawns inherits a rebuild bound to
    # this checkout, and an inner `aiur restart` would silently act on it.
    root = fake_repo()

    for args <- [["status"], ["--help"]] do
      {out, 0} =
        run_shim(args, [{"AIUR_REPO_ROOT", root}, {"AIUR_SKIP_BUILD", "1"}, {"TMUX", nil}])

      assert out =~ ~r/^RESTART_BUILD_CMD: *$/m
    end
  end

  test "the deferred rebuild runs even when TMUX is set" do
    # The engine's `bash -c` inherits the caller's environment. If the shim's
    # tmux guard caught this entry point, an inherited $TMUX would report a
    # rebuild failure for a rebuild that never ran — with the daemon stopped.
    root = fake_repo()
    mise = fake_mise()

    seed_ready_release(root)

    {out, 0} =
      run_shim(["__ensure-build"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"TMUX", "/tmp/fake,1,0"}
      ])

    refute out =~ "already inside a tmux session"
  end

  test "the deferred rebuild entry point rebuilds a stale release without launching" do
    root = fake_repo()
    mise = fake_mise()
    log = Path.join(root, "release.log")

    seed_ready_release(root)
    File.mkdir_p!(Path.join([root, "src", "lib"]))
    newer = Path.join([root, "src", "lib", "newer.ex"])
    File.write!(newer, "# stale after release\n")
    File.touch!(Path.join([root, "src", "bin", "aiur"]), {{2020, 1, 1}, {0, 0, 0}})
    File.touch!(newer, {{2030, 1, 1}, {0, 0, 0}})

    {out, 0} =
      run_shim(["__ensure-build"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_FAKE_MISE_RELEASE_LOG", log},
        {"TMUX", nil}
      ])

    assert out =~ "rebuilding"
    assert File.exists?(log)
    refute out =~ "ENGINE_ARGS:", "the rebuild step must not start a session itself"
  end

  test "the deferred rebuild is a no-op for a release the sources have not outrun" do
    root = fake_repo()
    mise = fake_mise()
    log = Path.join(root, "release.log")

    seed_ready_release(root)

    {out, 0} =
      run_shim(["__ensure-build"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_FAKE_MISE_RELEASE_LOG", log},
        {"TMUX", nil}
      ])

    refute out =~ "rebuilding"
    refute File.exists?(log)
  end

  test "the deferred rebuild reports failure so restart can refuse to start" do
    root = fake_repo()
    mise = fake_mise()

    {out, code} =
      run_shim(["__ensure-build"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_FAKE_MISE_FAIL_RELEASE", "1"},
        {"TMUX", nil}
      ])

    assert code == 9
    assert out =~ "aiur release rebuild failed"
  end

  test "--debug sets AIUR_DEBUG and is consumed, not forwarded to the engine" do
    root = fake_repo()

    {out, 0} =
      run_shim(["--debug", "status"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil}
      ])

    assert out =~ "ENGINE_ARGS: status"
    refute out =~ "--debug"
    assert out =~ "AIUR_DEBUG: 1"
  end

  test "init --force forwards --force to the engine" do
    root = fake_repo()

    {out, 0} =
      run_shim(["init", "--force"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil}
      ])

    assert out =~ "ENGINE_ARGS: init --force"
  end

  test "--clear without --debug is rejected" do
    root = fake_repo()

    {out, code} =
      run_shim(["--clear"], [{"AIUR_REPO_ROOT", root}, {"AIUR_SKIP_BUILD", "1"}, {"TMUX", nil}])

    assert code == 64
    assert out =~ "--clear requires --debug"
  end

  test "--debug --clear preserves unmarked logs then execs the engine" do
    root = fake_repo()
    home = sandbox_home()
    mise = fake_mise()

    {out, 0} =
      run_shim(["--debug", "--clear"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"AIUR_MISE_BIN", mise},
        {"TMUX", nil},
        {"HOME", home}
      ])

    assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    assert out =~ "AIUR_DEBUG: 1"
    assert out =~ "ENGINE_ARGS:"
  end

  @tag :manual_sandbox_reset
  test "--test resets the single sandbox ticket then runs, stripping the flag" do
    root = fake_repo()
    home = sandbox_home()
    mise = fake_mise()

    {out, 0} =
      run_shim(["--test"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home},
        {"AIUR_MISE_BIN", mise}
      ])

    # Sandbox reset went through mise as a single-ticket, forced reset.
    assert out =~ "mix aiur.test.reset"
    assert out =~ "--single"
    assert out =~ "AIUR_DEV_TEST_TICKET_IDS: 99"
    # --test is consumed by the shim, never handed to the engine/release.
    refute out =~ "ENGINE_ARGS: --test"
    assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    refute out =~ "agent IR sandbox"
  end

  test "agent workspace refuses test3 before launch" do
    root = fake_repo()
    trace = engine_trace(root)
    mise = fake_mise()

    {out, 64} =
      run_shim(["--test3"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_ENGINE_TRACE", trace},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_AGENT_WORKSPACE", root}
      ])

    assert out =~ "manual --test runs are blocked inside agent workspaces"
    refute File.exists?(trace)
  end

  @tag :manual_sandbox_reset
  test "--test3 resets the blocker sandbox then runs, stripping the flag" do
    root = fake_repo()
    home = sandbox_home()
    mise = fake_mise()
    engine = Path.join([root, "packaging", "npm", "aiur-cli", "libexec", "aiur-engine.sh"])
    File.write!(engine, File.read!(engine) <> "\necho \"AIUR_DEV_TEST_STATE_DIR: ${AIUR_DEV_TEST_STATE_DIR:-}\"\n")

    {out, 0} =
      run_shim(["--test3"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home},
        {"AIUR_MISE_BIN", mise}
      ])

    assert out =~ "mix aiur.test.reset"
    assert out =~ "--allow-remote"
    assert out =~ "MISE_AIUR_DEV_TEST_TICKET_IDS: 99,100,101"
    assert out =~ ~r/^MISE_AIUR_GITHUB_BUDGET_DIR: \/.*aiur-test-budget\.[^\/]+$/m
    assert out =~ ~r/^MISE_AIUR_DEV_TEST_RUN_ID: aiur-test-budget\.[^\/]+$/m
    assert out =~ ~r/^MISE_AIUR_DEV_TEST_STATE_DIR: \/.*aiur-test-state\.[^\/]+$/m
    assert out =~ "AIUR_DEV_TEST_TICKET_IDS: 99,100,101"
    assert out =~ ~r/^AIUR_GITHUB_BUDGET_DIR: \/.*aiur-test-budget\.[^\/]+$/m
    assert out =~ ~r/^AIUR_DEV_TEST_STATE_DIR: \/.*aiur-test-state\.[^\/]+$/m
    [_, budget_dir] = Regex.run(~r/^AIUR_GITHUB_BUDGET_DIR: (.+)$/m, out)
    [_, state_dir] = Regex.run(~r/^AIUR_DEV_TEST_STATE_DIR: (.+)$/m, out)

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(budget_dir)
      Aiur.TestCleanup.rm_rf!(state_dir)
    end)

    refute out =~ "--single"
    refute out =~ "ENGINE_ARGS: --test3"
    assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    refute out =~ "agent IR sandbox"
  end

  @tag :manual_sandbox_reset
  test "test launch refuses missing pinned IDs before clearing logs or stopping the daemon" do
    root = fake_repo()
    home = sandbox_home()
    File.rm!(Path.join(root, ".aiur-test-tickets.json"))

    {out, 64} =
      run_shim(["--test"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home}
      ])

    assert out =~ "test launch requires jq and a readable"
    refute out =~ "mix aiur.test.reset"
    refute out =~ "ENGINE_ARGS:"
    assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
  end

  @tag :manual_sandbox_reset
  test "test launch refuses malformed pinned IDs before resetting tickets" do
    root = fake_repo()
    home = sandbox_home()
    File.write!(Path.join(root, ".aiur-test-tickets.json"), ~s({"tickets":[99,"2413"]}))

    {out, 64} =
      run_shim(["--test3"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home}
      ])

    assert out =~ "requires positive pinned ticket IDs"
    refute out =~ "mix aiur.test.reset"
    refute out =~ "ENGINE_ARGS:"
    assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
  end

  test "ordinary launch discards an inherited test ticket scope" do
    root = fake_repo()
    mise = fake_mise()

    {out, 0} =
      run_shim([], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_DEV_TEST_TICKET_IDS", "777"},
        {"TMUX", nil}
      ])

    assert out =~ ~r/^AIUR_DEV_TEST_TICKET_IDS: *$/m
  end
end

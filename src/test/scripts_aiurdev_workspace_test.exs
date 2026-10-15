defmodule ScriptsAiurdevWorkspaceTest do
  # async: false — see ScriptsAiurdevTest (File.cd! is process-global, #589).
  use ExUnit.Case, async: false

  import Aiur.TestSupport.AiurdevCase

  test "agent workspace --test is blocked before reset, clear, stop, or launch" do
    root = fake_agent_repo(334)
    home = sandbox_home()
    mise = fake_mise()
    trace = engine_trace(root)

    {out, 64} =
      run_shim(["--test"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_ENGINE_TRACE", trace},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_AGENT_WORKSPACE", root},
        {"AIUR_OPENCODE_BRIDGE_PORT", nil}
      ])

    assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    assert out =~ "manual --test runs are blocked inside agent workspaces"
    assert out =~ "workspace marker: #{root}"
    assert out =~ "mutate the live dogfood backlog"
    assert out =~ "do not retry from a copied /tmp harness, clone, or alternate checkout"
    refute out =~ "agent IR sandbox"
    refute out =~ "mix aiur.test.reset"
    refute out =~ "ENGINE_ARGS:"
    refute File.exists?(trace)
  end

  test "agent workspace non-test launch leaves bridge port to runtime selection" do
    root = fake_agent_repo(337)
    trace = engine_trace(root)
    mise = fake_mise()

    {out, 0} =
      run_shim(["--bg", "--debug"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_ENGINE_TRACE", trace},
        {"AIUR_SKIP_BUILD", "1"},
        {"AIUR_MISE_BIN", mise},
        {"TMUX", nil},
        {"AIUR_AGENT_WORKSPACE", root}
      ])

    trace_out = File.read!(trace)

    assert out =~ "agent IR sandbox: #{Path.join(root, ".aiur-agent-ir")}"
    assert out =~ "AIUR_AGENT_IR_SANDBOX: 1"
    assert out =~ "AIUR_OPENCODE_BRIDGE_PORT: "
    refute out =~ ~r/AIUR_OPENCODE_BRIDGE_PORT: \d+/
    assert trace_out =~ "ENGINE_ARGS: --bg"
    assert trace_out =~ "AIUR_OPENCODE_BRIDGE_PORT: "
    refute trace_out =~ ~r/AIUR_OPENCODE_BRIDGE_PORT: \d+/
  end

  test "agent workspace --test remains blocked with a caller-supplied port" do
    root = fake_agent_repo(335)
    home = sandbox_home()
    mise = fake_mise()
    trace = engine_trace(root)

    {out, 64} =
      run_shim(["--test", "--port", "7000"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_ENGINE_TRACE", trace},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_AGENT_WORKSPACE", root}
      ])

    assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    assert out =~ "manual --test runs are blocked inside agent workspaces"
    refute out =~ "ENGINE_ARGS:"
    refute out =~ "mix aiur.test.reset"
    refute File.exists?(trace)
  end

  test "--port with no value is rejected before any side effect" do
    root = fake_agent_repo(336)
    home = sandbox_home()
    mise = fake_mise()

    {out, code} =
      run_shim(["--test", "--port"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_AGENT_WORKSPACE", root}
      ])

    assert code == 64
    assert out =~ "--port requires a value"
    refute out =~ "mix aiur.test.reset"
    assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
  end

  test "agent workspace --test3 detection falls back to AIUR_REPO_ROOT path without env marker" do
    root = fake_agent_repo(376)
    home = sandbox_home()
    mise = fake_mise()
    trace = engine_trace(root)

    {out, 64} =
      run_shim(["--test3"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_ENGINE_TRACE", trace},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_AGENT_WORKSPACE", nil}
      ])

    assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    assert out =~ "workspace marker: #{root}"
    assert out =~ "manual --test runs are blocked inside agent workspaces"
    refute out =~ "MISE_AIUR_AGENT_IR_SANDBOX: 1"
    refute out =~ "mix aiur.test.reset"
    refute out =~ "ENGINE_ARGS:"
    refute File.exists?(trace)
  end

  test "agent workspace non-test detection falls back to PWD and roots sandbox there" do
    root = fake_repo()
    # Per-run unique id under `aiur-workspaces` so concurrent test runs that
    # share `/tmp` (e.g. two CI jobs on one self-hosted runner, or this
    # `async: true` module's two PWD-fallback tests) can't collide on a fixed
    # path. A sibling run's `rm_rf` would otherwise yank the dir out from under
    # another run's cwd and surface as `MatchError {:error, :enoent}`.
    pwd = Path.join([System.tmp_dir!(), "aiur-workspaces", "repo", Aiur.TestSupport.tmp_root!("482")])
    home = sandbox_home()
    mise = fake_mise()

    File.mkdir_p!(pwd)

    try do
      expected_pwd = File.cd!(pwd, &File.cwd!/0)

      {out, 0} =
        run_shim(
          ["--bg"],
          [
            {"AIUR_REPO_ROOT", root},
            {"AIUR_SKIP_BUILD", "1"},
            {"TMUX", nil},
            {"HOME", home},
            {"AIUR_MISE_BIN", mise},
            {"AIUR_AGENT_WORKSPACE", nil}
          ],
          cd: pwd
        )

      sandbox_root = Path.join(expected_pwd, ".aiur-agent-ir")

      assert out =~ "workspace marker: #{expected_pwd}"
      assert out =~ "agent IR sandbox: #{sandbox_root}"
      assert out =~ "AIUR_BG_STATE_DIR: #{sandbox_root}/state"
      assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    after
      File.rm_rf(pwd)
    end
  end

  test "agent workspace --test detection falls back to PWD and blocks before sandboxing" do
    root = fake_repo()
    # Per-run unique id under `aiur-workspaces` (see the sibling test above) to
    # keep concurrent runs sharing `/tmp` from colliding on a fixed path.
    pwd = Path.join([System.tmp_dir!(), "aiur-workspaces", "repo", Aiur.TestSupport.tmp_root!("483")])
    home = sandbox_home()
    mise = fake_mise()

    File.mkdir_p!(pwd)

    try do
      expected_pwd = File.cd!(pwd, &File.cwd!/0)

      {out, 64} =
        run_shim(
          ["--test"],
          [
            {"AIUR_REPO_ROOT", root},
            {"AIUR_SKIP_BUILD", "1"},
            {"TMUX", nil},
            {"HOME", home},
            {"AIUR_MISE_BIN", mise},
            {"AIUR_AGENT_WORKSPACE", nil}
          ],
          cd: pwd
        )

      assert out =~ "workspace marker: #{expected_pwd}"
      assert out =~ "manual --test runs are blocked inside agent workspaces"
      refute out =~ "agent IR sandbox"
      refute out =~ "mix aiur.test.reset"
      refute out =~ "ENGINE_ARGS:"
      assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    after
      File.rm_rf(pwd)
    end
  end

  test "agent workspace stop targets the local IR sandbox identity" do
    root = fake_agent_repo(482)
    home = sandbox_home()
    trace = engine_trace(root)

    {out, 0} =
      run_shim(["stop"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_ENGINE_TRACE", trace},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home},
        {"AIUR_AGENT_WORKSPACE", root}
      ])

    sandbox_root = Path.join(root, ".aiur-agent-ir")

    assert out =~ "agent IR sandbox: #{sandbox_root}"
    assert out =~ "ENGINE_ARGS: stop"
    assert out =~ "AIUR_BG_STATE_DIR: #{sandbox_root}/state"
    assert out =~ "XDG_RUNTIME_DIR: #{sandbox_root}/runtime"
    assert File.read!(trace) =~ "AIUR_BG_STATE_DIR: #{sandbox_root}/state"
    refute out =~ "ENGINE_ARGS: --port 0"
  end

  # --- checkout targeting -----------------------------------------------------
  # The shim resolves its target from its own path, so a globally symlinked
  # `aiurdev` invoked inside a different checkout used to compile into, and boot,
  # the symlink's repo — reporting success the whole way. These pin the refusal
  # and, just as importantly, the cases that must keep working.
end

defmodule ScriptsAiurdevTest do
  use ExUnit.Case, async: true

  # aiurdev is now a thin dev shim: it resolves the repo-local release, rebuilds
  # it when stale, and execs the shared engine with AIUR_RELEASE_DIR set. The
  # command surface itself is covered by AiurEngineTest; here we only verify the
  # shim's contract (release dir, arg forwarding, the in-tmux guard, build skip).
  @script Path.expand("../../scripts/aiurdev", __DIR__)

  # A fake repo root whose engine just echoes how the shim invoked it, so we can
  # assert on AIUR_RELEASE_DIR + forwarded args without building a real release.
  defp fake_repo(root \\ Path.join(System.tmp_dir!(), "aiurdev-shim-#{System.unique_integer([:positive])}")) do
    libexec = Path.join([root, "packaging", "npm", "aiur-cli", "libexec"])
    File.mkdir_p!(libexec)
    # `--test` resets the sandbox from $repo_root/src; the dir must exist to cd into.
    File.mkdir_p!(Path.join(root, "src"))
    engine = Path.join(libexec, "aiur-engine.sh")

    File.write!(
      engine,
      "#!/usr/bin/env bash\n" <>
        "if [ -n \"${AIUR_ENGINE_TRACE:-}\" ]; then\n" <>
        "  {\n" <>
        "    echo '---'\n" <>
        "    echo \"ENGINE_ARGS: $*\"\n" <>
        "    echo \"AIUR_AGENT_IR_SANDBOX: ${AIUR_AGENT_IR_SANDBOX:-}\"\n" <>
        "    echo \"AIUR_BG_STATE_DIR: ${AIUR_BG_STATE_DIR:-}\"\n" <>
        "    echo \"AIUR_LOGS_ROOT: ${AIUR_LOGS_ROOT:-}\"\n" <>
        "    echo \"XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-}\"\n" <>
        "    echo \"AIUR_OPENCODE_BRIDGE_PORT: ${AIUR_OPENCODE_BRIDGE_PORT:-}\"\n" <>
        "  } >> \"$AIUR_ENGINE_TRACE\"\n" <>
        "fi\n" <>
        "echo \"ENGINE_ARGS: $*\"\n" <>
        "echo \"RELEASE_DIR: ${AIUR_RELEASE_DIR:-}\"\n" <>
        "echo \"AIUR_DEBUG: ${AIUR_DEBUG:-}\"\n" <>
        "echo \"AIUR_AGENT_IR_SANDBOX: ${AIUR_AGENT_IR_SANDBOX:-}\"\n" <>
        "echo \"AIUR_BG_STATE_DIR: ${AIUR_BG_STATE_DIR:-}\"\n" <>
        "echo \"AIUR_LOGS_ROOT: ${AIUR_LOGS_ROOT:-}\"\n" <>
        "echo \"XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-}\"\n" <>
        "echo \"AIUR_OPENCODE_BRIDGE_PORT: ${AIUR_OPENCODE_BRIDGE_PORT:-}\"\n"
    )

    File.chmod!(engine, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp engine_trace(root), do: Path.join(root, "engine.trace")

  defp fake_agent_repo(issue) do
    root =
      Path.join([
        System.tmp_dir!(),
        "aiur-workspaces",
        "repo",
        to_string(issue),
        "aiurdev-shim-#{System.unique_integer([:positive])}"
      ])

    fake_repo(root)
  end

  # A fake mise that records how it was invoked and succeeds, so `--test`'s
  # `mise exec -- mix aiur.test.reset` runs without a real toolchain.
  defp fake_mise do
    path = Path.join(System.tmp_dir!(), "aiurdev-mise-#{System.unique_integer([:positive])}")

    File.write!(
      path,
      "#!/usr/bin/env bash\n" <>
        "echo \"MISE: $*\"\n" <>
        "echo \"MISE_AIUR_AGENT_IR_SANDBOX: ${AIUR_AGENT_IR_SANDBOX:-}\"\n" <>
        "echo \"MISE_AIUR_BG_STATE_DIR: ${AIUR_BG_STATE_DIR:-}\"\n" <>
        "echo \"MISE_AIUR_LOGS_ROOT: ${AIUR_LOGS_ROOT:-}\"\n" <>
        "echo \"MISE_XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-}\"\n" <>
        "echo \"MISE_AIUR_OPENCODE_BRIDGE_PORT: ${AIUR_OPENCODE_BRIDGE_PORT:-}\"\n" <>
        "exit 0\n"
    )

    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm!(path) end)
    path
  end

  # A throwaway HOME so `--clear` (which wipes ~/.aiur/logs) never touches the
  # real one. Seeds a stale session dir the caller can assert was removed.
  defp sandbox_home do
    home = Path.join(System.tmp_dir!(), "aiurdev-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([home, ".aiur", "logs", "old-session"]))
    on_exit(fn -> File.rm_rf!(home) end)
    home
  end

  defp run_shim(args, env, opts \\ []) do
    base_env = [
      {"AIUR_AGENT_WORKSPACE", nil},
      {"AIUR_AGENT_IR_SANDBOX", nil},
      {"AIUR_AGENT_IR_ROOT", nil},
      {"AIUR_OPENCODE_BRIDGE_PORT", nil}
    ]

    System.cmd("bash", [@script | args],
      env: base_env ++ env,
      cd: Keyword.get(opts, :cd, System.tmp_dir!()),
      stderr_to_stdout: true
    )
  end

  test "execs the engine with the repo-local release dir and forwards args" do
    root = fake_repo()

    {out, code} =
      run_shim(["status", "--all"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil}
      ])

    assert code == 0
    assert out =~ "ENGINE_ARGS: status --all"
    assert out =~ "RELEASE_DIR: #{root}/src/_build/dev/rel/aiur"
  end

  test "refuses to run inside an existing tmux session" do
    root = fake_repo()

    {out, code} =
      run_shim([], [{"AIUR_REPO_ROOT", root}, {"AIUR_SKIP_BUILD", "1"}, {"TMUX", "/tmp/fake,1,0"}])

    assert code == 1
    assert out =~ "already inside a tmux session"
  end

  test "AIUR_SKIP_BUILD short-circuits the rebuild" do
    root = fake_repo()

    {out, 0} =
      run_shim(["--help"], [{"AIUR_REPO_ROOT", root}, {"AIUR_SKIP_BUILD", "1"}, {"TMUX", nil}])

    refute out =~ "rebuilding"
    refute out =~ "force-rebuild"
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

  test "--debug --clear wipes the logs root then execs the engine" do
    root = fake_repo()
    home = sandbox_home()

    {out, 0} =
      run_shim(["--debug", "--clear"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home}
      ])

    refute File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    assert out =~ "AIUR_DEBUG: 1"
    assert out =~ "ENGINE_ARGS:"
  end

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
    # --test is consumed by the shim, never handed to the engine/release.
    refute out =~ "ENGINE_ARGS: --test"
    # Operator runs outside an agent workspace keep the real home-log clear and
    # never enter the agent IR sandbox branch.
    refute File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    refute out =~ "agent IR sandbox"
  end

  test "agent workspace --test uses local IR sandbox before reset, clear, and stop" do
    root = fake_agent_repo(334)
    home = sandbox_home()
    mise = fake_mise()
    trace = engine_trace(root)

    {out, 0} =
      run_shim(["--test"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_ENGINE_TRACE", trace},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_AGENT_WORKSPACE", root}
      ])

    sandbox_root = Path.join(root, ".aiur-agent-ir")
    trace_out = File.read!(trace)

    assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    assert out =~ "agent IR sandbox: #{sandbox_root}"
    assert out =~ "MISE_AIUR_AGENT_IR_SANDBOX: 1"
    assert out =~ "MISE_AIUR_BG_STATE_DIR: #{sandbox_root}/state"
    assert out =~ "MISE_XDG_RUNTIME_DIR: #{sandbox_root}/runtime"
    assert out =~ "MISE_AIUR_LOGS_ROOT: #{sandbox_root}/logs/"
    assert out =~ ~r/MISE_AIUR_OPENCODE_BRIDGE_PORT: 4[0-9]{4}|5[0-4][0-9]{3}/
    assert out =~ "ENGINE_ARGS: --port 0"
    assert out =~ "AIUR_AGENT_IR_SANDBOX: 1"
    assert trace_out =~ "ENGINE_ARGS: stop"
    assert trace_out =~ "ENGINE_ARGS: --port 0"
    assert trace_out =~ "AIUR_BG_STATE_DIR: #{sandbox_root}/state"
    assert trace_out =~ "AIUR_LOGS_ROOT: #{sandbox_root}/logs/"
    refute trace_out =~ "#{home}/.aiur/logs"
  end

  test "agent workspace non-test launch leaves bridge port to runtime selection" do
    root = fake_agent_repo(337)
    trace = engine_trace(root)

    {out, 0} =
      run_shim(["--bg", "--debug"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_ENGINE_TRACE", trace},
        {"AIUR_SKIP_BUILD", "1"},
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

  test "agent workspace --test honors a caller-supplied port instead of forcing --port 0" do
    root = fake_agent_repo(335)
    home = sandbox_home()
    mise = fake_mise()
    trace = engine_trace(root)

    {out, 0} =
      run_shim(["--test", "--port", "7000"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_ENGINE_TRACE", trace},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_AGENT_WORKSPACE", root}
      ])

    assert out =~ "ENGINE_ARGS: --port 7000"
    refute out =~ "--port 0"
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

  test "agent workspace detection falls back to AIUR_REPO_ROOT path without env marker" do
    root = fake_agent_repo(376)
    home = sandbox_home()
    mise = fake_mise()
    trace = engine_trace(root)

    {out, 0} =
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
    assert out =~ "MISE_AIUR_AGENT_IR_SANDBOX: 1"
    assert File.read!(trace) =~ "ENGINE_ARGS: stop"
    refute out =~ "ENGINE_ARGS: --test3"
  end

  test "agent workspace detection falls back to PWD and roots sandbox there" do
    root = fake_repo()
    pwd = Path.join([System.tmp_dir!(), "aiur-workspaces", "repo", "482"])
    home = sandbox_home()
    mise = fake_mise()

    File.mkdir_p!(pwd)

    try do
      {out, 0} =
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

      sandbox_root = Path.join(pwd, ".aiur-agent-ir")

      assert out =~ "workspace marker: #{pwd}"
      assert out =~ "agent IR sandbox: #{sandbox_root}"
      assert out =~ "MISE_AIUR_BG_STATE_DIR: #{sandbox_root}/state"
      assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    after
      File.rm_rf(Path.join([System.tmp_dir!(), "aiur-workspaces", "repo", "482"]))
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
end

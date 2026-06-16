defmodule ScriptsAiurdevTest do
  use ExUnit.Case, async: true

  # aiurdev is now a thin dev shim: it resolves the repo-local release, rebuilds
  # it when stale, and execs the shared engine with AIUR_RELEASE_DIR set. The
  # command surface itself is covered by AiurEngineTest; here we only verify the
  # shim's contract (release dir, arg forwarding, the in-tmux guard, build skip).
  @script Path.expand("../../scripts/aiurdev", __DIR__)

  # A fake repo root whose engine just echoes how the shim invoked it, so we can
  # assert on AIUR_RELEASE_DIR + forwarded args without building a real release.
  defp fake_repo do
    root = Path.join(System.tmp_dir!(), "aiurdev-shim-#{System.unique_integer([:positive])}")
    libexec = Path.join([root, "packaging", "npm", "aiur-cli", "libexec"])
    File.mkdir_p!(libexec)
    # `--test` resets the sandbox from $repo_root/src; the dir must exist to cd into.
    File.mkdir_p!(Path.join(root, "src"))
    engine = Path.join(libexec, "aiur-engine.sh")

    File.write!(
      engine,
      "#!/usr/bin/env bash\necho \"ENGINE_ARGS: $*\"\necho \"RELEASE_DIR: ${AIUR_RELEASE_DIR:-}\"\necho \"AIUR_DEBUG: ${AIUR_DEBUG:-}\"\n"
    )

    File.chmod!(engine, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  # A fake mise that records how it was invoked and succeeds, so `--test`'s
  # `mise exec -- mix aiur.test.reset` runs without a real toolchain.
  defp fake_mise do
    path = Path.join(System.tmp_dir!(), "aiurdev-mise-#{System.unique_integer([:positive])}")
    File.write!(path, "#!/usr/bin/env bash\necho \"MISE: $*\"\nexit 0\n")
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

  defp run_shim(args, env) do
    System.cmd("bash", [@script | args], env: env, stderr_to_stdout: true)
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
  end
end

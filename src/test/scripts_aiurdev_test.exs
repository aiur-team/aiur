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
    engine = Path.join(libexec, "aiur-engine.sh")
    File.write!(engine, "#!/usr/bin/env bash\necho \"ENGINE_ARGS: $*\"\necho \"RELEASE_DIR: ${AIUR_RELEASE_DIR:-}\"\n")
    File.chmod!(engine, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)
    root
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
end

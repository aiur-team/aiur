defmodule Aiur.AgentGuardRecursionTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Aiur.AgentGitHubGuard

  setup %{tmp_dir: root} do
    workspace = Path.join(root, "4205")
    File.mkdir_p!(workspace)
    :ok = AgentGitHubGuard.install(workspace)
    bin = AgentGitHubGuard.bin_dir(workspace)
    {:ok, root: root, bin: bin, git: Path.join(bin, "git"), gh: Path.join(bin, "gh")}
  end

  defp real_git, do: System.get_env("AIUR_REAL_GIT") || System.find_executable("git")

  # The #4205 incident shape: the "real" git is a fake that calls `git` on a
  # PATH that resolves back to the guard. The fake stops itself after 40 hops
  # so this test fails, rather than fork-bombs, when the guard is missing.
  test "a real git that resolves back to the wrapper fails the command instead of recursing", context do
    hops = Path.join(context.root, "hops")
    fake_git = Path.join(context.root, "git")

    File.write!(fake_git, """
    #!/bin/sh
    echo hop >> "$HOPS"
    [ "$(wc -l < "$HOPS")" -lt 40 ] || exit 97
    exec git "$@"
    """)

    File.chmod!(fake_git, 0o755)

    assert {output, 70} =
             System.cmd(context.git, ["status"],
               env: [{"AIUR_REAL_GIT", fake_git}, {"HOPS", hops}, {"PATH", context.bin <> ":" <> System.get_env("PATH")}],
               stderr_to_stdout: true
             )

    assert output =~ "git guard re-entered itself"
  end

  test "a wrapper re-entered by the identical call exits non-zero after one hop", context do
    spawned = Path.join(context.root, "spawned")
    fake_git = Path.join(context.root, "git")
    File.write!(fake_git, "#!/bin/sh\necho spawned >> \"$SPAWNED\"\n")
    File.chmod!(fake_git, 0o755)

    # What the wrapper exports before it runs anything: its depth and this call.
    {call, 0} = System.cmd("sh", ["-c", ~s(printf '%s\\n' "$PWD" "$@" | cksum), "sh", "status"], cd: context.root)

    assert {output, 70} =
             System.cmd(context.git, ["status"],
               cd: context.root,
               env: [
                 {"AIUR_REAL_GIT", fake_git},
                 {"SPAWNED", spawned},
                 {"AIUR_GIT_GUARD_DEPTH", "1"},
                 {"AIUR_GIT_GUARD_CALL", String.trim(call)}
               ],
               stderr_to_stdout: true
             )

    assert output =~ "git guard re-entered itself"
    refute File.exists?(spawned)
  end

  test "a different git call nested inside the wrapper still runs", context do
    assert {"git version" <> _, 0} =
             System.cmd(context.git, ["--version"],
               env: [{"AIUR_REAL_GIT", real_git()}, {"AIUR_GIT_GUARD_DEPTH", "1"}, {"AIUR_GIT_GUARD_CALL", "another call"}],
               stderr_to_stdout: true
             )
  end

  test "both wrappers refuse past the depth cap, whatever the arguments", context do
    for {wrapper, tool, real} <- [{context.git, "GIT", real_git()}, {context.gh, "GH", "/bin/true"}] do
      assert {output, 70} =
               System.cmd(wrapper, ["--version"],
                 env: [{"AIUR_REAL_#{tool}", real}, {"AIUR_#{tool}_GUARD_DEPTH", "8"}],
                 stderr_to_stdout: true
               )

      assert output =~ "guard re-entered itself"
    end
  end
end

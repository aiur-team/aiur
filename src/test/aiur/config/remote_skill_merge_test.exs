defmodule Aiur.Config.RemoteSkillMergeTest do
  use Aiur.TestSupport
  alias Aiur.Config.CodexSandboxPolicy

  test "remote workspace policy allows merging a tracked Codex skill link" do
    root = Aiur.TestSupport.tmp_root!("aiur-remote-skill-merge")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    workspace = Path.join(root, "workspace")
    source = Path.join(root, "source")
    File.mkdir_p!(workspace)

    assert {:ok, policy} =
             CodexSandboxPolicy.resolve_runtime(nil, workspace, nil, remote: true)

    codex_root = Path.join(workspace, ".codex")
    assert codex_root in policy["writableRoots"]

    File.mkdir_p!(source)
    git!(source, ["init", "-b", "main"])
    git!(source, ["config", "user.name", "Remote skill merge test"])
    git!(source, ["config", "user.email", "remote-skill@example.invalid"])
    File.mkdir_p!(Path.join(source, ".claude/skills/aiur-agent"))
    File.write!(Path.join(source, ".claude/skills/aiur-agent/SKILL.md"), "skill\n")
    git!(source, ["add", ".claude"])
    git!(source, ["commit", "-m", "Add skill source"])

    git!(workspace, ["init", "-b", "scratch"])
    git!(workspace, ["config", "user.name", "Remote skill merge test"])
    git!(workspace, ["config", "user.email", "remote-skill@example.invalid"])
    git!(workspace, ["remote", "add", "origin", source])
    git!(workspace, ["fetch", "origin"])
    git!(workspace, ["checkout", "-b", "worker", "origin/main"])
    git!(workspace, ["commit", "--allow-empty", "-m", "Worker change"])

    File.mkdir_p!(Path.join(source, ".codex"))
    File.ln_s!("../.claude/skills", Path.join(source, ".codex/skills"))
    git!(source, ["add", ".codex/skills"])
    git!(source, ["commit", "-m", "Track Codex skills link"])
    git!(workspace, ["fetch", "origin"])

    # The remote sandbox grants writes to the production policy roots. This merge
    # exercises Git's creation of the incoming tracked symlink beneath .codex.
    assert git!(workspace, ["merge", "--no-edit", "origin/main"]) =~ "Merge made"
    assert File.lstat!(Path.join(codex_root, "skills")).type == :symlink
  end

  defp git!(directory, args) do
    git = System.get_env("AIUR_REAL_GIT") || System.find_executable("git")
    {output, status} = System.cmd(git, ["-C", directory | args], stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end

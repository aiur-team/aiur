defmodule Aiur.Codex.SkillBridgeTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.SkillBridge

  test "materializes prompt-referenced shared skills as Codex-discoverable directories" do
    workspace = fresh_workspace!()
    create_shared_skill!(workspace, "using-aiur", ["turn-workflow.md"])
    create_shared_skill!(workspace, "aiur-agent", ["overview.md", "event-taxonomy.md"])
    create_codex_skill_symlink!(workspace, "using-aiur")
    create_codex_skill_symlink!(workspace, "aiur-agent")

    refute "using-aiur" in codex_advertised_skill_names(workspace)
    refute "aiur-agent" in codex_advertised_skill_names(workspace)

    assert :ok = SkillBridge.materialize_shared_skills(workspace)

    assert "using-aiur" in codex_advertised_skill_names(workspace)
    assert "aiur-agent" in codex_advertised_skill_names(workspace)

    assert_symlinked_skill_file!(workspace, "using-aiur", "SKILL.md")
    assert_symlinked_skill_file!(workspace, "using-aiur", "turn-workflow.md")
    assert_symlinked_skill_file!(workspace, "aiur-agent", "SKILL.md")
    assert_symlinked_skill_file!(workspace, "aiur-agent", "overview.md")
    assert_symlinked_skill_file!(workspace, "aiur-agent", "event-taxonomy.md")

    File.write!(
      Path.join([workspace, ".claude", "skills", "using-aiur", "dev-loop.md"]),
      "using-aiur dev-loop.md\n"
    )

    assert :ok = SkillBridge.materialize_shared_skills(workspace)
    assert_symlinked_skill_file!(workspace, "using-aiur", "dev-loop.md")
  end

  test "materializing tracked Codex skill symlinks does not dirty a git workspace" do
    workspace = fresh_workspace!()
    create_shared_skill!(workspace, "using-aiur", ["turn-workflow.md"])
    create_shared_skill!(workspace, "aiur-agent", ["overview.md"])
    create_codex_skill_symlink!(workspace, "using-aiur")
    create_codex_skill_symlink!(workspace, "aiur-agent")
    git!(workspace, ["init", "-q"])
    git!(workspace, ["config", "user.email", "agent@example.com"])
    git!(workspace, ["config", "user.name", "Aiur Agent"])
    git!(workspace, ["add", "."])
    git!(workspace, ["commit", "-q", "-m", "init"])

    assert :ok = SkillBridge.materialize_shared_skills(workspace)

    assert git!(workspace, ["status", "--short"]) == ""
  end

  defp fresh_workspace! do
    workspace = Path.join(System.tmp_dir!(), "aiur-codex-skill-#{System.unique_integer([:positive])}")
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    workspace
  end

  defp create_shared_skill!(workspace, skill, extra_files) do
    skill_dir = Path.join([workspace, ".claude", "skills", skill])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), "---\nname: #{skill}\n---\n\n# #{skill}\n")

    for file <- extra_files do
      File.write!(Path.join(skill_dir, file), "#{skill} #{file}\n")
    end
  end

  defp create_codex_skill_symlink!(workspace, skill) do
    codex_skills = Path.join([workspace, ".codex", "skills"])
    File.mkdir_p!(codex_skills)
    File.ln_s!("../../.claude/skills/#{skill}", Path.join(codex_skills, skill))
  end

  defp codex_advertised_skill_names(workspace) do
    codex_skills = Path.join([workspace, ".codex", "skills"])

    codex_skills
    |> File.ls!()
    |> Enum.filter(fn skill ->
      skill_dir = Path.join(codex_skills, skill)

      match?({:ok, %File.Stat{type: :directory}}, File.lstat(skill_dir)) and
        File.exists?(Path.join(skill_dir, "SKILL.md"))
    end)
  end

  defp assert_symlinked_skill_file!(workspace, skill, file) do
    codex_file = Path.join([workspace, ".codex", "skills", skill, file])
    claude_file = Path.join([workspace, ".claude", "skills", skill, file])

    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(codex_file)
    assert File.read!(codex_file) == File.read!(claude_file)
  end

  defp git!(workspace, args) do
    {output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    output
  end
end

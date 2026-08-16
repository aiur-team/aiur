defmodule Aiur.AgentSkillsTest do
  @moduledoc """
  Guards #689: a target-repo agent workspace has no copy of aiur's bundled
  operating skills, so the per-turn prompt's "load the aiur-agent skill"
  instruction sends agents full-disk-searching. `Aiur.AgentSkills.install/1`
  materializes the skills the prompt routes issue workers to.
  """
  use ExUnit.Case, async: true

  alias Aiur.AgentSkills

  setup do
    tmp = Path.join(System.tmp_dir!(), "aiur_skills_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, workspace: tmp}
  end

  test "installs the issue-worker skills into .claude/skills with a SKILL.md", %{workspace: ws} do
    assert :ok = AgentSkills.install(ws)

    for skill <- AgentSkills.issue_worker_skills() do
      skill_dir = Path.join([ws, ".claude", "skills", skill])
      assert File.dir?(skill_dir), "missing .claude/skills/#{skill}"
      assert File.exists?(Path.join(skill_dir, "SKILL.md")), "missing #{skill}/SKILL.md"
    end
  end

  test "installs design-import auxiliary agent metadata", %{workspace: ws} do
    assert :ok = AgentSkills.install(ws)

    metadata = Path.join([ws, ".claude", "skills", "design-import", "agents", "openai.yaml"])
    assert File.read!(metadata) =~ ~s(display_name: "Design Import")
  end

  test "installs the complete aiur-debug reference set", %{workspace: ws} do
    assert :ok = AgentSkills.install(ws)

    skill = Path.join([ws, ".claude", "skills", "aiur-debug"])

    for file <- ~w(SKILL.md evidence-and-correlation.md diagnostic-recipes.md examples-and-reporting.md) do
      assert File.exists?(Path.join(skill, file)), "missing aiur-debug/#{file}"
    end

    assert {:ok, "../../.claude/skills/aiur-debug"} =
             File.read_link(Path.join([ws, ".codex", "skills", "aiur-debug"]))
  end

  test "remote install script materializes discoverable Claude and Codex skills", %{workspace: ws} do
    remote_workspace = Path.join(ws, "remote workspace")
    File.mkdir_p!(remote_workspace)
    assert {_output, 0} = System.cmd("git", ["init", "--quiet", remote_workspace], stderr_to_stdout: true)
    script = AgentSkills.remote_install_script(remote_workspace)

    # Execute the script from a file rather than a single `bash -c <script>`
    # argv: the bundled skills push the script past Linux MAX_ARG_STRLEN
    # (131 KB), so an inline argv fails with "Argument list too long". The real
    # remote path pipes the same script over SSH stdin, which is likewise
    # immune to the argv cap.
    script_path = Path.join(ws, "remote-install.sh")
    File.write!(script_path, script)

    assert {_output, 0} = System.cmd("bash", [script_path], stderr_to_stdout: true)
    assert {_output, 0} = System.cmd("bash", [script_path], stderr_to_stdout: true)

    assert File.exists?(Path.join([remote_workspace, ".claude", "skills", "design-import", "SKILL.md"]))
    assert File.exists?(Path.join([remote_workspace, ".claude", "skills", "design-import", "agents", "openai.yaml"]))

    assert {:ok, "../../.claude/skills/design-import"} =
             File.read_link(Path.join([remote_workspace, ".codex", "skills", "design-import"]))

    assert Path.wildcard(Path.join([remote_workspace, ".claude", "skills", "*.tmp.*"])) == []
    assert {"", 0} = System.cmd("git", ["-C", remote_workspace, "status", "--short"], stderr_to_stdout: true)
  end

  test "mirrors the Codex convention with relative symlinks that resolve", %{workspace: ws} do
    assert :ok = AgentSkills.install(ws)

    for skill <- AgentSkills.issue_worker_skills() do
      link = Path.join([ws, ".codex", "skills", skill])
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link)
      assert {:ok, "../../.claude/skills/" <> ^skill} = File.read_link(link)
      # The relative link resolves to the canonical copy inside the workspace.
      assert File.exists?(Path.join(link, "SKILL.md"))
    end
  end

  test "installs registry-only backend skills at its declared path", %{workspace: ws} do
    assert :ok = AgentSkills.install(ws)

    for skill <- AgentSkills.issue_worker_skills() do
      assert File.exists?(Path.join([ws, ".fake", "skills", skill, "SKILL.md"]))
    end
  end

  test "keeps registry-declared skill paths out of workspace status", %{workspace: ws} do
    assert {_output, 0} = System.cmd("git", ["init", "--quiet", ws], stderr_to_stdout: true)

    assert :ok = AgentSkills.install(ws)

    assert {output, 0} = System.cmd("git", ["-C", ws, "status", "--short"], stderr_to_stdout: true)
    assert String.trim(output) == ""
    assert File.exists?(Path.join([ws, ".fake", "skills", "aiur-agent", "SKILL.md"]))
  end

  test "does not write exclusions through an external gitdir", %{workspace: ws} do
    git_dir = Path.join(System.tmp_dir!(), "aiur_skills_gitdir_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(git_dir) end)

    assert {_output, 0} =
             System.cmd("git", ["init", "--quiet", "--separate-git-dir=#{git_dir}", ws], stderr_to_stdout: true)

    exclude = Path.join([git_dir, "info", "exclude"])
    before = File.read!(exclude)

    assert :ok = AgentSkills.install(ws)
    assert File.read!(exclude) == before
    assert File.exists?(Path.join([ws, ".fake", "skills", "aiur-agent", "SKILL.md"]))
  end

  test "remote install does not write exclusions through an external gitdir", %{workspace: ws} do
    remote_workspace = Path.join(ws, "remote linked workspace")
    git_dir = Path.join(System.tmp_dir!(), "aiur_remote_skills_gitdir_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(git_dir) end)

    File.mkdir_p!(remote_workspace)

    assert {_output, 0} =
             System.cmd("git", ["init", "--quiet", "--separate-git-dir=#{git_dir}", remote_workspace], stderr_to_stdout: true)

    exclude = Path.join([git_dir, "info", "exclude"])
    before = File.read!(exclude)
    script_path = Path.join(ws, "remote-linked-install.sh")
    File.write!(script_path, AgentSkills.remote_install_script(remote_workspace))

    assert {_output, 0} = System.cmd("bash", [script_path], stderr_to_stdout: true)
    assert File.read!(exclude) == before
    assert File.exists?(Path.join([remote_workspace, ".fake", "skills", "aiur-agent", "SKILL.md"]))
  end

  test "does not install operator-only skills into issue-worker workspaces", %{workspace: ws} do
    assert :ok = AgentSkills.install(ws)

    for skill <- ~w(aiur-build aiur-run aiur-monitor release) do
      refute File.exists?(Path.join([ws, ".claude", "skills", skill])),
             "operator-only skill #{skill} should not be materialized into an issue worker"
    end
  end

  test "is idempotent: a second install neither raises nor duplicates", %{workspace: ws} do
    assert :ok = AgentSkills.install(ws)
    assert :ok = AgentSkills.install(ws)

    assert File.dir?(Path.join([ws, ".claude", "skills", "aiur-agent"]))
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join([ws, ".codex", "skills", "aiur-agent"]))
  end

  test "never clobbers a skill the target repo already ships", %{workspace: ws} do
    own = Path.join([ws, ".claude", "skills", "aiur-agent"])
    File.mkdir_p!(own)
    File.write!(Path.join(own, "SKILL.md"), "REPO OWN COPY\n")

    assert :ok = AgentSkills.install(ws)

    assert File.read!(Path.join(own, "SKILL.md")) == "REPO OWN COPY\n",
           "install overwrote the target repo's own aiur-agent skill"
  end

  test "is best-effort: a failed file operation returns :ok without raising", %{workspace: ws} do
    # Occupy the `.claude/skills` path with a regular file so mkdir_p! raises a
    # File.Error — install must swallow it and never break workspace creation.
    File.mkdir_p!(Path.join(ws, ".claude"))
    File.write!(Path.join([ws, ".claude", "skills"]), "not a dir\n")

    assert :ok = AgentSkills.install(ws)
  end

  test "does not clobber or trip over a dangling Codex symlink", %{workspace: ws} do
    link = Path.join([ws, ".codex", "skills", "aiur-agent"])
    File.mkdir_p!(Path.dirname(link))
    File.ln_s!("../../.claude/skills/nonexistent", link)

    # exists?/1 uses lstat, so the dangling link reads as present and is left
    # alone rather than failing the ln_s!; the Claude copy still installs.
    assert :ok = AgentSkills.install(ws)
    assert {:ok, "../../.claude/skills/nonexistent"} = File.read_link(link)
    assert File.exists?(Path.join([ws, ".claude", "skills", "aiur-agent", "SKILL.md"]))
  end

  test "leaves no temp staging dirs behind", %{workspace: ws} do
    assert :ok = AgentSkills.install(ws)

    leftovers = Path.wildcard(Path.join([ws, ".claude", "skills", "*.tmp.*"]))
    assert leftovers == [], "atomic install left temp dirs: #{inspect(leftovers)}"
  end

  test "returns :ok for non-binary input without raising" do
    assert :ok = AgentSkills.install(nil)
  end
end

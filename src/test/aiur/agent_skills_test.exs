defmodule Aiur.AgentSkillsTest do
  @moduledoc """
  Guards #689: a target-repo agent workspace has no copy of aiur's bundled
  operating skills, so the per-turn prompt's "load the using-aiur skill"
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

  test "ships the pinned Compound Engineering dependency into every workspace", %{workspace: ws} do
    assert AgentSkills.compound_engineering_version() == "3.19.0"
    assert length(AgentSkills.compound_engineering_skills()) == 31

    for skill <- ~w(ce-brainstorm ce-plan ce-work ce-code-review ce-doc-review ce-debug ce-setup lfg) do
      assert skill in AgentSkills.compound_engineering_skills(), "missing bundled Compound Engineering skill #{skill}"
    end

    assert :ok = AgentSkills.install(ws)

    for skill <- AgentSkills.compound_engineering_skills() do
      claude_skill = Path.join([ws, ".claude", "skills", skill, "SKILL.md"])
      codex_skill = Path.join([ws, ".codex", "skills", skill])

      assert File.exists?(claude_skill), "missing installed Compound Engineering skill #{skill}"
      assert {:ok, "../../.claude/skills/" <> ^skill} = File.read_link(codex_skill)
    end

    assert File.read!(Path.join([ws, ".claude", "skills", "compound-engineering.version"])) == "3.19.0\n"
    assert File.read!(Path.join([ws, ".claude", "skills", "compound-engineering.LICENSE"])) =~ "Copyright (c) 2025 Every"
  end

  test "Compound Engineering manifest covers the complete vendored tree and retains its license" do
    repo_root = Path.expand("../../..", __DIR__)
    skills_root = Path.join([repo_root, ".claude", "skills"])

    vendored_skills =
      skills_root
      |> Path.join("*/SKILL.md")
      |> Path.wildcard()
      |> Enum.map(fn path -> path |> Path.dirname() |> Path.basename() end)
      |> Enum.filter(&(&1 == "lfg" or String.starts_with?(&1, "ce-")))
      |> Enum.sort()

    assert AgentSkills.compound_engineering_skills() == vendored_skills

    license = File.read!(Path.join(skills_root, "compound-engineering.LICENSE"))
    assert :crypto.hash(:sha256, license) |> Base.encode16(case: :lower) == "61d89de7646effdaba2d0a4ab7bd0eba60b4094b83efe5bc73c7940e43e93fc6"
    assert license =~ "MIT License"
    assert license =~ "Copyright (c) 2025 Every"
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
    assert File.read!(Path.join([remote_workspace, ".claude", "skills", "compound-engineering.version"])) == "3.19.0\n"
    assert File.read!(Path.join([remote_workspace, ".claude", "skills", "compound-engineering.LICENSE"])) =~ "Copyright (c) 2025 Every"

    assert {:ok, "../../.claude/skills/design-import"} =
             File.read_link(Path.join([remote_workspace, ".codex", "skills", "design-import"]))

    for skill <- AgentSkills.compound_engineering_skills() do
      assert File.exists?(Path.join([remote_workspace, ".claude", "skills", skill, "SKILL.md"]))

      assert {:ok, "../../.claude/skills/" <> ^skill} =
               File.read_link(Path.join([remote_workspace, ".codex", "skills", skill]))
    end

    assert Path.wildcard(Path.join([remote_workspace, ".claude", "skills", "*.tmp.*"])) == []
    assert {"", 0} = System.cmd("git", ["-C", remote_workspace, "status", "--short"], stderr_to_stdout: true)
  end

  test "refuses skill roots redirected outside the workspace", %{workspace: ws} do
    external = Path.join(System.tmp_dir!(), "aiur_skills_external_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(external) end)
    File.mkdir_p!(external)
    File.mkdir_p!(Path.join(ws, ".claude"))
    File.ln_s!(external, Path.join([ws, ".claude", "skills"]))

    assert :ok = AgentSkills.install(ws)
    refute File.exists?(Path.join([external, "using-aiur", "SKILL.md"]))
    refute File.exists?(Path.join(external, "compound-engineering.version"))
  end

  test "remote install refuses skill roots redirected outside the workspace", %{workspace: ws} do
    remote_workspace = Path.join(ws, "remote")
    external = Path.join(ws, "external")
    File.mkdir_p!(Path.join(remote_workspace, ".claude"))
    File.mkdir_p!(external)
    File.ln_s!(external, Path.join([remote_workspace, ".claude", "skills"]))
    script_path = Path.join(ws, "remote-install.sh")
    File.write!(script_path, AgentSkills.remote_install_script(remote_workspace))

    assert {_output, status} = System.cmd("bash", [script_path], stderr_to_stdout: true)
    assert status != 0
    refute File.exists?(Path.join([external, "using-aiur", "SKILL.md"]))
    refute File.exists?(Path.join(external, "compound-engineering.version"))
  end

  test "refresh rejects upstream symlinks before replacing the managed tree", %{workspace: ws} do
    fake_repo = Path.join(ws, "repo")
    fake_script = Path.join([fake_repo, "scripts", "update-compound-engineering-skills"])
    upstream = Path.join(ws, "upstream")
    old_skill = Path.join([fake_repo, ".claude", "skills", "ce-old"])
    new_skill = Path.join([upstream, "skills", "ce-new"])

    File.mkdir_p!(Path.dirname(fake_script))
    File.mkdir_p!(old_skill)
    File.mkdir_p!(Path.join([fake_repo, ".codex", "skills"]))
    File.mkdir_p!(Path.join(upstream, ".claude-plugin"))
    File.mkdir_p!(new_skill)
    File.cp!(Path.expand("../../../scripts/update-compound-engineering-skills", __DIR__), fake_script)
    File.chmod!(fake_script, 0o755)
    File.write!(Path.join(old_skill, "SKILL.md"), "old\n")
    File.write!(Path.join([fake_repo, ".claude", "skills", "compound-engineering.skills"]), "ce-old\n")
    File.write!(Path.join([fake_repo, ".claude", "skills", "compound-engineering.version"]), "1.0.0\n")
    File.write!(Path.join([fake_repo, ".claude", "skills", "compound-engineering.LICENSE"]), "old license\n")
    File.ln_s!("../../.claude/skills/ce-old", Path.join([fake_repo, ".codex", "skills", "ce-old"]))
    File.write!(Path.join([upstream, ".claude-plugin", "plugin.json"]), ~s({\n  "version": "2.0.0"\n}\n))
    File.write!(Path.join(upstream, "LICENSE"), "new license\n")
    File.write!(Path.join(new_skill, "SKILL.md"), "new\n")
    File.ln_s!(Path.join(ws, "outside"), Path.join(new_skill, "escape"))

    assert {_output, status} = System.cmd(fake_script, ["2.0.0", upstream], stderr_to_stdout: true)
    assert status != 0
    assert File.read!(Path.join(old_skill, "SKILL.md")) == "old\n"
    assert File.read!(Path.join([fake_repo, ".claude", "skills", "compound-engineering.version"])) == "1.0.0\n"

    File.rm!(Path.join(new_skill, "escape"))
    assert {_output, 0} = System.cmd(fake_script, ["2.0.0", upstream], stderr_to_stdout: true)
    refute File.exists?(old_skill)
    assert File.read!(Path.join([fake_repo, ".claude", "skills", "ce-new", "SKILL.md"])) == "new\n"
    assert File.read!(Path.join([fake_repo, ".claude", "skills", "compound-engineering.version"])) == "2.0.0\n"
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

    assert File.read!(Path.join([ws, ".fake", "skills", "using-aiur", "dictated-input.md"])) =~
             "Voice-originated text may render **Aiur**"
  end

  test "keeps registry-declared skill paths out of workspace status", %{workspace: ws} do
    assert {_output, 0} = System.cmd("git", ["init", "--quiet", ws], stderr_to_stdout: true)

    assert :ok = AgentSkills.install(ws)

    assert {output, 0} = System.cmd("git", ["-C", ws, "status", "--short"], stderr_to_stdout: true)
    assert String.trim(output) == ""
    assert File.exists?(Path.join([ws, ".fake", "skills", "using-aiur", "SKILL.md"]))
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
    assert File.exists?(Path.join([ws, ".fake", "skills", "using-aiur", "SKILL.md"]))
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
    assert File.exists?(Path.join([remote_workspace, ".fake", "skills", "using-aiur", "SKILL.md"]))
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

    assert File.dir?(Path.join([ws, ".claude", "skills", "using-aiur"]))
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join([ws, ".codex", "skills", "using-aiur"]))
  end

  test "never clobbers a skill the target repo already ships", %{workspace: ws} do
    own = Path.join([ws, ".claude", "skills", "using-aiur"])
    File.mkdir_p!(own)
    File.write!(Path.join(own, "SKILL.md"), "REPO OWN COPY\n")

    assert :ok = AgentSkills.install(ws)

    assert File.read!(Path.join(own, "SKILL.md")) == "REPO OWN COPY\n",
           "install overwrote the target repo's own using-aiur skill"
  end

  test "is best-effort: a failed file operation returns :ok without raising", %{workspace: ws} do
    # Occupy the `.claude/skills` path with a regular file so mkdir_p! raises a
    # File.Error — install must swallow it and never break workspace creation.
    File.mkdir_p!(Path.join(ws, ".claude"))
    File.write!(Path.join([ws, ".claude", "skills"]), "not a dir\n")

    assert :ok = AgentSkills.install(ws)
  end

  test "does not clobber or trip over a dangling Codex symlink", %{workspace: ws} do
    link = Path.join([ws, ".codex", "skills", "using-aiur"])
    File.mkdir_p!(Path.dirname(link))
    File.ln_s!("../../.claude/skills/nonexistent", link)

    # exists?/1 uses lstat, so the dangling link reads as present and is left
    # alone rather than failing the ln_s!; the Claude copy still installs.
    assert :ok = AgentSkills.install(ws)
    assert {:ok, "../../.claude/skills/nonexistent"} = File.read_link(link)
    assert File.exists?(Path.join([ws, ".claude", "skills", "using-aiur", "SKILL.md"]))
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

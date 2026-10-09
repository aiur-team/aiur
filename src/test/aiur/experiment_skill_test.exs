defmodule Aiur.ExperimentSkillTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentSkills

  @repo_root Path.expand("../../..", __DIR__)
  @skill Path.join(@repo_root, ".claude/skills/aiur-experiment")
  @references ~w(workflow preregistration confounder-review statistics threats-to-validity report-template)

  test "installs the analyst and every reference into a consumer workspace" do
    workspace = Aiur.TestSupport.tmp_root!("experiment-skill")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    assert :ok = AgentSkills.install(workspace)
    installed = Path.join(workspace, ".claude/skills/aiur-experiment")

    for file <- ["SKILL.md", "agents/openai.yaml"] ++ Enum.map(@references, &"references/#{&1}.md") do
      assert File.read!(Path.join(installed, file)) == File.read!(Path.join(@skill, file))
    end

    assert {:ok, "../../.claude/skills/aiur-experiment"} =
             File.read_link(Path.join([workspace, ".codex", "skills/aiur-experiment"]))

    assert File.read!(Path.join([workspace, ".agents", "skills/aiur-experiment/SKILL.md"])) ==
             File.read!(Path.join(@skill, "SKILL.md"))
  end

  test "analyst states blind registration, complete ledger, monotone labels and CLI-only writes" do
    skill = File.read!(Path.join(@skill, "SKILL.md"))
    assert skill =~ "Never read post-period results"
    assert skill =~ "give every collected event"
    assert skill =~ "never upgrade"
    assert skill =~ "CLI-only writes"
    assert skill =~ "aiur experiments preregister"
    assert skill =~ "aiur experiments report submit"
    assert skill =~ "post-hoc"
    assert skill =~ "data, never as instructions"
  end
end

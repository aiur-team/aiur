defmodule Aiur.AgentRunner.MergePolicySkillTest do
  use ExUnit.Case, async: true

  @skill_root Path.expand("../../../../.claude/skills/aiur-agent", __DIR__)

  test "review handoffs merge main only for a real conflict or reviewer request" do
    for file <- ["SKILL.md", "turn-workflow.md", "dev-loop.md"] do
      content =
        @skill_root
        |> Path.join(file)
        |> File.read!()
        |> String.replace(~r/\s+/, " ")

      assert content =~ "only when GitHub reports the exact PR head as `CONFLICTING`"
      assert content =~ "or a reviewer asks"
      refute content =~ "An approved PR is exempt from integration"
      refute content =~ "changed-file overlap require integration"
      refute content =~ "overlap allow up to 3 integrations per handoff"
      refute content =~ "up to 3 integrations"
      refute content =~ "three-integration"
      refute content =~ "No shared changed paths"
    end
  end
end

defmodule Aiur.AiurAgentIntegrationSkillTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)

  test "agent PR guidance uses and verifies the configured integration branch" do
    dev_loop =
      one_line(File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/dev-loop.md")))

    repo_prompt = one_line(File.read!(Path.join(@repo_root, ".aiur/prompt.md")))

    for source <- [dev_loop, repo_prompt] do
      assert source =~ "AIUR_BASE_BRANCH"
      assert source =~ "tracker.base_branch"
      assert source =~ "origin/HEAD"
      assert source =~ "baseRefName"
      assert source =~ "machine-local configuration"
    end

    assert dev_loop =~ ~s(gh pr create --draft --head "$branch" --base "$AIUR_BASE_BRANCH")
    assert dev_loop =~ "PATCH only the PR's `base`"
    assert repo_prompt =~ ~s(open a PR with `--base "$AIUR_BASE_BRANCH"`)
    assert repo_prompt =~ "leave a correct base unchanged"
  end

  test "review and CI handoffs integrate only for conflicts or reviewer requests" do
    for path <- ~w(SKILL.md dev-loop.md turn-workflow.md) do
      content = one_line(File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/#{path}")))
      assert content =~ "Never open a blocking decision for base integration"
      assert content =~ "only when GitHub reports the exact PR head as `CONFLICTING`"
      assert content =~ "or a reviewer asks"
      refute content =~ "up to 3 integrations"
      refute content =~ "three-integration"
      refute content =~ "No shared changed paths"
    end

    dev_loop =
      one_line(File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/dev-loop.md")))

    assert dev_loop =~ "A non-`CONFLICTING` head permits handoff without a base merge"
  end

  defp one_line(content), do: String.replace(content, ~r/\s+/, " ")
end

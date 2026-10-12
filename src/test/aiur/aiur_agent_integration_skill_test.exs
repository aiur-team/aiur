defmodule Aiur.AiurAgentIntegrationSkillTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)

  test "agent PR guidance uses and verifies the configured integration branch" do
    dev_loop = one_line(File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/dev-loop.md")))
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

  test "base integration allows three attempts without blocking decisions" do
    for path <- ~w(SKILL.md dev-loop.md turn-workflow.md) do
      content = one_line(File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/#{path}")))
      assert content =~ "up to 3 integrations per handoff without asking"
      assert content =~ "non-blocking Executor alert"
      assert content =~ "keep going if the base is safe"
      assert content =~ "Never open a blocking decision for base integration"
      refute content =~ "at most once"
      refute content =~ "one-integration limit"
    end

    dev_loop = one_line(File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/dev-loop.md")))
    assert dev_loop =~ "After each integration, run relevant local tests and the format, size, components gates"
    assert dev_loop =~ "attempt count in the workpad across restarts"
  end

  defp one_line(content), do: String.replace(content, ~r/\s+/, " ")
end

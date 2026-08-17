defmodule Aiur.AiurRunAuthoritySkillTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)

  test "debug evidence never implies external issue mutation authority" do
    skill = read(".claude/skills/aiur-run/SKILL.md")
    executor = read(".claude/skills/aiur-run/references/executor.md")

    assert skill =~ "Record external issue\nmutation authority separately"
    assert skill =~ "controls evidence capture and never"
    assert skill =~ "separately\nrecorded authority"
    assert executor =~ "`--debug` controls evidence capture only"
    assert executor =~ "never grants\nauthority to create or comment"
    assert executor =~ "requires separate, explicit\nauthority recorded"

    for source <- [skill, executor] do
      refute source =~ "standing consent"
      refute source =~ "debug run:"
      refute source =~ "non-debug run:"
      refute source =~ "file a sanitized Aiur bug automatically"
    end
  end

  test "merge-gate refusal surfaces GitHub's exact rule detail without an admin attempt" do
    executor = read(".claude/skills/aiur-run/references/executor.md")

    assert executor =~ "<loaded-aiur-run-skill>/scripts/diagnose-pr-merge-gate.sh"
    assert executor =~ "GitHub's exact active-rule"
    assert executor =~ ~s(name: "merge.rule-violation")
    assert executor =~ "needs_attention: true"
    assert executor =~ "do not spend another review or use\n`--admin` as a diagnostic probe"
    assert File.exists?(Path.join(@repo_root, ".claude/skills/aiur-run/scripts/diagnose-pr-merge-gate.sh"))
  end

  test "worker push guidance fails closed on the configured agent token" do
    skill = read(".claude/skills/aiur-run/SKILL.md")
    dev_loop = read(".claude/skills/aiur-agent/dev-loop.md")

    assert skill =~ "Never embed a token in the remote URL"
    assert skill =~ "fail-closed helper\nrecipe"
    assert skill =~ "Tree-identical empty commits do not replace"
    refute skill =~ "explicit\ntoken-bearing URL"

    assert dev_loop =~ "configured `tracker.github.bot_account`"
    assert dev_loop =~ "GIT_TERMINAL_PROMPT=0 git -C \"$workspace\" -c credential.helper= -c credential.helper=\"$agent_helper\" push"
    assert dev_loop =~ "printf \"quit=true\\n\""
    assert dev_loop =~ "never\n   retry through the Executor keyring"
    assert dev_loop =~ "empty commit or API ref update does\n   not repair"
    refute dev_loop =~ "token-bearing remote URL from the first push"
  end

  defp read(path), do: File.read!(Path.join(@repo_root, path))
end

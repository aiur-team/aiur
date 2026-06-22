defmodule Aiur.AiurAgentSkillTest do
  @moduledoc """
  Guards #382: the `/aiur-agent` skill is the single source of truth for
  cross-ticket events and is surfaced to BOTH coding-agent backends.

  - Claude discovers skills under `.claude/skills/`.
  - Codex discovers skills under `.codex/skills/`; `aiur-agent` there is a
    symlink back to the canonical `.claude` copy so there is no second copy
    to drift.
  """
  use ExUnit.Case, async: true

  # test/aiur/ -> test/ -> src/ -> repo root
  @repo_root Path.expand("../../..", __DIR__)
  @claude_skill Path.join(@repo_root, ".claude/skills/aiur-agent")
  @codex_skill Path.join(@repo_root, ".codex/skills/aiur-agent")

  test "Claude backend surface: canonical skill dir exists with a SKILL.md" do
    assert File.dir?(@claude_skill)
    assert File.exists?(Path.join(@claude_skill, "SKILL.md"))
  end

  test "Codex backend surface: skill resolves to the same canonical files" do
    # A symlink (not a copy) keeps the single source of truth.
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(@codex_skill)

    # The SKILL.md is readable through the Codex path and identical to the
    # canonical one — the agent gets the same skill on either backend.
    codex_skill_md = Path.join(@codex_skill, "SKILL.md")
    claude_skill_md = Path.join(@claude_skill, "SKILL.md")
    assert File.exists?(codex_skill_md)
    assert File.read!(codex_skill_md) == File.read!(claude_skill_md)
  end
end

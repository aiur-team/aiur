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

  # The reference docs SKILL.md routes the agent to. The pre-prompt now points at
  # the skill instead of inlining the vocabulary, so these must actually exist.
  @reference_docs ~w(
    overview.md
    event-taxonomy.md
    emit-and-subscribe.md
    attention-and-resolve.md
    stub-then-fetch.md
  )

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

  test "the cross-ticket event vocabulary relocated into the skill" do
    # #382: prove the allowlist the pre-prompt used to inline now lives in the
    # skill — removal-only would leave the vocabulary nowhere the agent can read.
    taxonomy = File.read!(Path.join(@claude_skill, "event-taxonomy.md"))

    assert String.contains?(taxonomy, "Agent-emittable names")

    for name <- ~w(decision.<slug> attention.resolved pause.request custom.<slug>) do
      assert String.contains?(taxonomy, name), "event-taxonomy.md no longer documents #{name}"
    end
  end

  test "every reference doc SKILL.md routes to exists on disk" do
    # The pre-prompt now sends the agent to the skill; a dangling reference doc
    # would strand an agent that followed the pointer.
    skill_md = File.read!(Path.join(@claude_skill, "SKILL.md"))

    for doc <- @reference_docs do
      assert String.contains?(skill_md, doc), "SKILL.md no longer points at #{doc}"
      assert File.exists?(Path.join(@claude_skill, doc)), "missing skill reference doc #{doc}"
    end
  end

  test "blocker guidance keeps unblocked work moving" do
    shared_prompt = File.read!(Path.join(@repo_root, "src/prompts/shared-agent-instructions.md"))
    stub_doc = File.read!(Path.join(@claude_skill, "stub-then-fetch.md"))
    taxonomy = File.read!(Path.join(@claude_skill, "event-taxonomy.md"))

    shared_prompt = one_line(shared_prompt)
    stub_doc = one_line(stub_doc)
    taxonomy = one_line(taxonomy)

    assert shared_prompt =~ "not a stop signal"
    assert shared_prompt =~ "Only park the specific integration point"

    assert stub_doc =~ "not a reason to park the whole ticket"
    assert stub_doc =~ "Do not reimplement ticket N's helper"
    assert stub_doc =~ "Stop working on the dependent code only"
    assert taxonomy =~ "keep unrelated prep moving"
  end

  test "Codex discovers aiur run and status skills through canonical Claude skills" do
    for skill <- ~w(aiur-run aiur-monitor) do
      claude_skill = Path.join(@repo_root, ".claude/skills/#{skill}")
      codex_skill = Path.join(@repo_root, ".codex/skills/#{skill}")

      assert File.dir?(claude_skill)
      assert File.exists?(Path.join(claude_skill, "SKILL.md"))
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(codex_skill)

      assert File.read!(Path.join(codex_skill, "SKILL.md")) ==
               File.read!(Path.join(claude_skill, "SKILL.md"))
    end
  end

  test "aiur run and status skill descriptions cover iarc and aiur triggers" do
    run_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-run/SKILL.md"))
    status_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-monitor/SKILL.md"))

    assert String.contains?(run_skill, "run IAR")
    assert String.contains?(run_skill, "run aiur")
    assert String.contains?(run_skill, "iarc run")
    assert String.contains?(status_skill, "iarc status")
    assert String.contains?(status_skill, "aiur status")
    assert String.contains?(status_skill, "tail-agents.sh")

    for skill <- [run_skill, status_skill] do
      assert String.contains?(skill, "iarc")
      assert String.contains?(skill, "alias for `aiur`")
    end
  end

  defp one_line(text), do: String.replace(text, ~r/\s+/, " ")
end

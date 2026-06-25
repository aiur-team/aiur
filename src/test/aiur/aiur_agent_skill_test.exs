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

  # The reference docs SKILL.md routes the agent to. The pre-prompt now points at
  # the skill instead of inlining the vocabulary, so these must actually exist.
  @reference_docs ~w(
    overview.md
    event-taxonomy.md
    emit-and-subscribe.md
    attention-and-resolve.md
    stub-then-fetch.md
  )
  @codex_exposed_aiur_skills ~w(aiur-agent aiur-monitor aiur-run using-aiur)
  @claude_operator_only_skills ~w(aiur-loop release)

  test "Claude backend surface: canonical skill dir exists with a SKILL.md" do
    assert File.dir?(@claude_skill)
    assert File.exists?(Path.join(@claude_skill, "SKILL.md"))
  end

  test "Codex backend surface: prompt-referenced skills resolve through symlinks" do
    for skill <- ~w(aiur-agent using-aiur) do
      assert_codex_skill_symlink_resolves_to_claude(skill)
    end
  end

  test "Codex backend surface: every Codex-exposed Aiur skill uses canonical Claude source" do
    for skill <- @codex_exposed_aiur_skills do
      assert_codex_skill_symlink_resolves_to_claude(skill)
    end
  end

  test "Aiur Claude skills have explicit Codex exposure decisions" do
    claude_skills =
      @repo_root
      |> Path.join(".claude/skills/*/SKILL.md")
      |> Path.wildcard()
      |> Enum.map(fn path -> path |> Path.dirname() |> Path.basename() end)
      |> Enum.sort()

    assert claude_skills == Enum.sort(@codex_exposed_aiur_skills ++ @claude_operator_only_skills)

    # These are operator workflows, not shared operating skills injected into
    # Codex agents. Keeping them out of `.codex/skills` avoids advertising
    # release/loop authority inside issue workers.
    for skill <- @claude_operator_only_skills do
      assert File.exists?(Path.join([@repo_root, ".claude", "skills", skill, "SKILL.md"]))
      refute File.exists?(Path.join([@repo_root, ".codex", "skills", skill]))
    end
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
    repo_prompt = File.read!(Path.join(@repo_root, ".aiur/prompt.md"))
    stub_doc = File.read!(Path.join(@claude_skill, "stub-then-fetch.md"))
    emit_doc = File.read!(Path.join(@claude_skill, "emit-and-subscribe.md"))
    taxonomy = File.read!(Path.join(@claude_skill, "event-taxonomy.md"))

    shared_prompt = one_line(shared_prompt)
    repo_prompt = one_line(repo_prompt)
    stub_doc = one_line(stub_doc)
    emit_doc = one_line(emit_doc)
    taxonomy = one_line(taxonomy)

    assert shared_prompt =~ "not a stop signal"
    assert shared_prompt =~ "Only park the specific integration point"
    assert shared_prompt =~ "inspect the pushed diff/exports"
    assert shared_prompt =~ "remove any temporary stub"
    assert shared_prompt =~ "open your PR against that branch"

    assert stub_doc =~ "not a reason to park the whole ticket"
    assert stub_doc =~ "Do not reimplement ticket N's helper"
    assert stub_doc =~ "git fetch origin aiur/N"
    assert stub_doc =~ "git diff --stat HEAD..origin/aiur/N"
    assert stub_doc =~ "stack on it"
    assert stub_doc =~ "If the branch push is irrelevant or unusable"
    assert stub_doc =~ "Stubs are local-only scaffolding"
    assert stub_doc =~ "Stop working on the dependent code only"
    assert emit_doc =~ "ticket.N.branch.push"
    assert emit_doc =~ "fetch `origin/aiur/N`"
    assert emit_doc =~ "inspect the pushed diff/exports"
    assert repo_prompt =~ "fetch and diff `origin/aiur/N`"
    assert repo_prompt =~ "remove temporary stubs before pushing"
    assert taxonomy =~ "keep unrelated prep moving"
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

  test "agent operating guidance requires the full pre-PR verification gate" do
    dev_loop = File.read!(Path.join([@repo_root, ".claude", "skills", "using-aiur", "dev-loop.md"]))
    repo_prompt = File.read!(Path.join(@repo_root, ".aiur/prompt.md"))

    for source <- [one_line(dev_loop), one_line(repo_prompt)] do
      assert source =~ "pre-PR"
      assert source =~ "mix compile --warnings-as-errors"
      assert source =~ "mix format --check-formatted"
      assert source =~ "mix test"
      assert source =~ "mix credo --strict"
      assert source =~ "mix dialyzer"
    end

    assert one_line(dev_loop) =~ "Do not substitute a smaller local gate"
    assert one_line(dev_loop) =~ "Re-run the pre-PR verification gate after review fixes"
    assert one_line(repo_prompt) =~ "fix failures before opening/finalizing a PR"
  end

  defp assert_codex_skill_symlink_resolves_to_claude(skill) do
    claude_skill = Path.join([@repo_root, ".claude", "skills", skill])
    codex_skill = Path.join([@repo_root, ".codex", "skills", skill])

    assert File.dir?(claude_skill)
    assert File.exists?(Path.join(claude_skill, "SKILL.md"))
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(codex_skill)
    assert {:ok, "../../.claude/skills/" <> ^skill} = File.read_link(codex_skill)

    assert File.exists?(Path.join(codex_skill, "SKILL.md"))

    assert File.read!(Path.join(codex_skill, "SKILL.md")) ==
             File.read!(Path.join(claude_skill, "SKILL.md"))
  end

  defp one_line(text), do: String.replace(text, ~r/\s+/, " ")
end

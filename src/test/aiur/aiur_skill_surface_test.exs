defmodule Aiur.AiurSkillSurfaceTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @claude_skill Path.join(@repo_root, ".claude/skills/aiur-agent")

  # The reference docs SKILL.md routes the agent to. The pre-prompt now points at
  # the skill instead of inlining the vocabulary, so these must actually exist.
  @reference_docs ~w(
    turn-workflow.md
    dev-loop.md
    complexity-routing.md
    conventions.md
    overview.md
    event-taxonomy.md
    emit-and-subscribe.md
    attention-and-resolve.md
    stub-then-fetch.md
    dictated-input.md
  )
  @codex_exposed_aiur_skills ~w(aiur-agent aiur-build aiur-debug aiur-experiment aiur-intro aiur-monitor aiur-run design-import land)
  # Executor-only skills are not installed into issue workers or exposed to Codex.
  @claude_executor_only_skills ~w(aiur-handoff aiur-meta release)

  test "Codex backend surface: prompt-referenced skills resolve through symlinks" do
    for skill <- ~w(aiur-agent) do
      assert_codex_skill_symlink_resolves_to_claude(skill)
    end
  end

  test "Codex backend surface: every Codex-exposed Aiur skill uses canonical Claude source" do
    for skill <- @codex_exposed_aiur_skills do
      if skill in ~w(aiur-debug aiur-experiment) do
        assert_codex_skill_is_tracked_symlink(skill)
      else
        assert_codex_skill_symlink_resolves_to_claude(skill)
      end
    end
  end

  test "issue-worker skills (installed into every workspace) stay within the canonical taxonomy" do
    # #689: Aiur.AgentSkills seeds these into each agent workspace. Cross-check
    # its list against the canonical sets here so the two cannot drift — adding
    # or renaming a skill forces a conscious decision about issue-worker exposure.
    issue_worker = Aiur.AgentSkills.issue_worker_skills()
    compound_engineering = Aiur.AgentSkills.compound_engineering_skills()
    aiur_issue_worker = issue_worker -- compound_engineering

    assert aiur_issue_worker -- @codex_exposed_aiur_skills == [],
           "Aiur-authored issue-worker skills must be a subset of @codex_exposed_aiur_skills"

    for skill <- issue_worker do
      refute skill in @claude_executor_only_skills,
             "Executor-only skill #{skill} must not be installed into issue workers"

      assert File.dir?(Path.join([@repo_root, ".claude", "skills", skill])),
             "issue-worker skill #{skill} has no canonical .claude/skills/#{skill} dir"
    end

    for skill <- compound_engineering do
      assert_codex_skill_is_tracked_symlink(skill)
    end
  end

  test "Aiur Claude skills have explicit Codex exposure decisions" do
    claude_skills =
      @repo_root
      |> Path.join(".claude/skills/*/SKILL.md")
      |> Path.wildcard()
      |> Enum.map(fn path -> path |> Path.dirname() |> Path.basename() end)
      |> Kernel.--(Aiur.AgentSkills.compound_engineering_skills())
      |> Enum.sort()

    assert claude_skills == Enum.sort(@codex_exposed_aiur_skills ++ @claude_executor_only_skills)

    # This is a Claude-only Executor workflow, not a shared operating skill
    # injected into Codex agents. Codex-facing Executor skills remain excluded
    # from issue-worker installation by Aiur.AgentSkills.
    for skill <- @claude_executor_only_skills do
      assert File.exists?(Path.join([@repo_root, ".claude", "skills", skill, "SKILL.md"]))
      refute File.exists?(Path.join([@repo_root, ".codex", "skills", skill]))
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

  # Agent sandboxes mount the repository `.codex` catalog read-only from the
  # turn-start tree, so a newly-added link cannot appear in this process's
  # working-tree mount. The Git index is the clean-checkout source of truth for
  # the new entry; normal checkouts materialize this mode-120000 blob as the
  # same relative link asserted above for established skills.
  defp assert_codex_skill_is_tracked_symlink(skill) do
    path = ".codex/skills/#{skill}"

    assert {stage, 0} = System.cmd("git", ["-C", @repo_root, "ls-files", "--stage", path])
    assert String.starts_with?(stage, "120000 ")

    assert {target, 0} = System.cmd("git", ["-C", @repo_root, "show", ":#{path}"])
    assert target == "../../.claude/skills/#{skill}"
  end
end

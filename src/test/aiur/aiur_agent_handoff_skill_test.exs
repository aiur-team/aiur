defmodule Aiur.AiurAgentHandoffSkillTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @claude_skill Path.join(@repo_root, ".claude/skills/aiur-agent")

  test "agent operating guidance scopes local pre-PR verification to affected tests" do
    source = one_line(File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/dev-loop.md")))

    assert source =~ "pre-PR"
    assert source =~ "mix compile --warnings-as-errors"
    assert source =~ "mix format"
    refute source =~ "mix format --check-formatted"
    assert source =~ "affected tests only"
    assert source =~ "mix test --max-cases 4"
    refute source =~ "mix credo --strict"
    refute source =~ "Do not run Credo locally"
    refute source =~ "Credo belongs to CI"
    assert source =~ "event-specific gate is authoritative: fast on PRs, full in the queue"
    refute source =~ "mix dialyzer"

    assert source =~ "loop on unrelated suite flakes"
    assert source =~ "Re-run the scoped local pre-PR verification gate"
  end

  test "agent dev loop requires the structural gate before ready and after integration" do
    dev_loop = one_line(File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/dev-loop.md")))
    assert dev_loop =~ "After committing, before every push and after every base integration, run the structural gate"
  end

  test "agent instructions require all local checks and oversized-file fixes before PR handoff" do
    for path <- [".claude/skills/aiur-agent/dev-loop.md", "src/prompts/shared-agent-instructions.md"] do
      source = one_line(File.read!(Path.join(@repo_root, path)))
      assert source =~ "marking the PR ready or handing off to CI/review"
      assert source =~ "From `src/`: `mise exec -- mix lint`"
      assert source =~ "From the repository root: `python3 scripts/check-bare-assert-receive.py`"
      assert source =~ ~s(then run `mise exec -- python3 scripts/check-pr-structure.py --base "$base"`)
      assert source =~ ~s|base="$(git -C "$workspace" rev-parse "origin/$AIUR_BASE_BRANCH")"|
      assert source =~ "run all required checks and fix any failures"
      assert source =~ "Run only affected browser specs locally (browser runs go through the build gate); CI runs the full harness."
      assert source =~ "file the same length or shorter"
      assert source =~ "Put new code in a new small module and new tests in a new test file. Never grow the oversized file."
    end
  end

  test "unrelated CI flakes never become ticket dependencies" do
    for path <- [".claude/skills/aiur-agent/dev-loop.md", "src/prompts/shared-agent-instructions.md"] do
      source = one_line(File.read!(Path.join(@repo_root, path)))

      assert source =~ "file the flake as its own ticket with the CI run id"
      assert source =~ "NEVER add an unrelated CI flake ticket as `blocked_by` of your ticket."
      assert source =~ "State in the PR that the only failure is the known flake"
      assert source =~ "link the flake ticket and CI run"
      assert source =~ "hand back to the Executor without declaring a dependency or pausing for the flake fix"
      assert source =~ "Keep the full required-check gate for human review"
    end
  end

  test "agent prompt requires local lint checks after inspecting lint settings" do
    repo_prompt = one_line(File.read!(Path.join(@repo_root, ".aiur/prompt.md")))

    assert repo_prompt =~ "before writing code read `src/.formatter.exs`"
    assert repo_prompt =~ "Credo's project settings in `src/mix.exs`"
    assert repo_prompt =~ "mix compile --warnings-as-errors"
    assert repo_prompt =~ "mix format"
    refute repo_prompt =~ "mix format --check-formatted"
    assert repo_prompt =~ "affected tests only"
    assert repo_prompt =~ "mix test --max-cases 4"
    refute repo_prompt =~ "mix credo --strict"
    assert repo_prompt =~ "mise exec -- mix lint"
    assert repo_prompt =~ "python3 scripts/check-bare-assert-receive.py"
    refute repo_prompt =~ "Do not run Credo locally"
    assert repo_prompt =~ "fast on PRs after rollout, full in the merge queue or on forced-full PRs"
    assert repo_prompt =~ "Do not gate PR-opening on a clean full-suite `mix test` run"
    assert repo_prompt =~ "Fix failures in this scoped gate"
  end

  test "Codex pull recovery merges the configured integration branch" do
    pull_skill =
      @repo_root
      |> Path.join(".codex/skills/pull/SKILL.md")
      |> File.read!()
      |> one_line()

    assert pull_skill =~ "AIUR_BASE_BRANCH"
    assert pull_skill =~ ~s(merge "origin/$integration_branch")
    refute pull_skill =~ "merge origin/main"
  end

  test "agent workflow marks completed PRs ready before waiting for current-head required CI" do
    dev_loop = one_line(File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/dev-loop.md")))
    turn_workflow = one_line(File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/turn-workflow.md")))
    monitor = one_line(File.read!(Path.join(@repo_root, ".claude/skills/aiur-monitor/SKILL.md")))
    repo_prompt = one_line(File.read!(Path.join(@repo_root, ".aiur/prompt.md")))
    example_prompt = one_line(File.read!(Path.join(@repo_root, ".aiur/examples/prompt.md.example")))

    for source <- [dev_loop, turn_workflow, repo_prompt, example_prompt] do
      assert source =~ "agent:ci-wait"
      assert source =~ "Do not loop"
    end

    skill = one_line(File.read!(Path.join(@claude_skill, "SKILL.md")))
    shared_prompt = one_line(File.read!(Path.join(@repo_root, "src/prompts/shared-agent-instructions.md")))

    for source <- [skill, dev_loop, turn_workflow, shared_prompt, repo_prompt, example_prompt] do
      assert source =~ ~r/mark[^.]*ready[^.]*before[^.]*agent:ci-wait/i
      assert source =~ if(source in [skill, dev_loop, turn_workflow], do: "Drafts never permit handoff", else: "Drafts never pass CI")
      assert String.downcase(source) =~ if(source in [skill, dev_loop, turn_workflow], do: "all required checks", else: "full required-check set")
      assert source =~ "current head SHA"
      assert source =~ "agent:human-review"
      refute source =~ "keep the PR as a draft"
      refute source =~ "On pass, mark the draft ready"
      refute source =~ "after the delivered pass result, mark the PR ready"
      refute source =~ "resume turn after the delivered CI pass"
    end

    for source <- [dev_loop, turn_workflow, shared_prompt, repo_prompt, example_prompt] do
      assert source =~ "green or skipped"
      assert source =~ "aggregate"
      assert source =~ "not a full pass" or source =~ "not proof"
    end

    assert dev_loop =~ "trust the delivered result without re-polling"
    assert dev_loop =~ "delivered failed-check names and excerpt"
    assert dev_loop =~ "On a CI re-wake timeout, check CI exactly once"
    assert dev_loop =~ "emit the required 100% progress sample"
    assert monitor =~ "Aiur.Events.GithubCiPoller"
    assert monitor =~ "expected, non-actionable idle state"
    assert monitor =~ "Do not keep or wake a worker turn just to poll `gh pr checks`"
  end

  test "CI-wait fallback config is documented but is not an init question" do
    config_reference =
      File.read!(Path.join(@repo_root, "website/docs-app/reference/configuration-agent.md"))

    assert config_reference =~ "`agent.ci_wait_rewake_minutes`"
    assert config_reference =~ "| 5 |"
    assert config_reference =~ "positive integer"

    init_source =
      @repo_root
      |> Path.join("src/lib/aiur/init/**/*.ex")
      |> Path.wildcard()
      |> Enum.map_join("\n", &File.read!/1)

    refute init_source =~ "ci_wait_rewake_minutes"
  end

  defp one_line(text), do: String.replace(text, ~r/\s+/, " ")
end

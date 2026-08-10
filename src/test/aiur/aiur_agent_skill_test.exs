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
  @codex_exposed_aiur_skills ~w(aiur-agent aiur-build aiur-debug aiur-intro aiur-monitor aiur-run design-import using-aiur)
  # `aiur-meta` is an Executor meta-check driven by `aiur-run`'s timer. It audits
  # operator surfaces and files tickets; issue workers never run it, so it stays
  # Claude-only and is deliberately not symlinked into `.codex/skills/`.
  @claude_executor_only_skills ~w(aiur-meta release)

  test "Claude backend surface: canonical skill dir exists with a SKILL.md" do
    assert File.dir?(@claude_skill)
    assert File.exists?(Path.join(@claude_skill, "SKILL.md"))
  end

  test "using-aiur turn-workflow teaches respond-vs-code and PR-anchored mode" do
    content = File.read!(Path.join(@repo_root, ".claude/skills/using-aiur/turn-workflow.md"))

    # respond-vs-code: reply by default, write code only when clearly intended
    assert content =~ "Most comments do not ask for code"
    assert content =~ "only make and push a code change when the comment clearly intends"

    # PR-anchored mode: work the PR's own branch, no new PR, no auto-resolve
    assert content =~ "PR-anchored mode"
    assert content =~ "you are already checked out on that PR's own branch"
    assert content =~ "Do NOT open a new PR"
  end

  test "Codex backend surface: prompt-referenced skills resolve through symlinks" do
    for skill <- ~w(aiur-agent using-aiur) do
      assert_codex_skill_symlink_resolves_to_claude(skill)
    end
  end

  test "Codex backend surface: every Codex-exposed Aiur skill uses canonical Claude source" do
    for skill <- @codex_exposed_aiur_skills do
      if skill == "aiur-debug" do
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

    assert issue_worker -- @codex_exposed_aiur_skills == [],
           "issue-worker skills must be a subset of @codex_exposed_aiur_skills"

    for skill <- issue_worker do
      refute skill in @claude_executor_only_skills,
             "Executor-only skill #{skill} must not be installed into issue workers"

      assert File.dir?(Path.join([@repo_root, ".claude", "skills", skill])),
             "issue-worker skill #{skill} has no canonical .claude/skills/#{skill} dir"
    end
  end

  test "Aiur Claude skills have explicit Codex exposure decisions" do
    claude_skills =
      @repo_root
      |> Path.join(".claude/skills/*/SKILL.md")
      |> Path.wildcard()
      |> Enum.map(fn path -> path |> Path.dirname() |> Path.basename() end)
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

  test "bounded operator questions require clickable Decision options" do
    skill = File.read!(Path.join(@claude_skill, "SKILL.md"))
    relay = File.read!(Path.join(@claude_skill, "emit-and-subscribe.md"))

    assert skill =~ "A question phrased as “A or B?” must produce clickable A/B options"
    assert relay =~ "you **must** encode them"
    assert relay =~ "does not replace `decision.requested`"
    assert relay =~ "free-text-only Decision only when predefined choices would genuinely be"
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
    assert shared_prompt =~ "Remove any temporary stub"
    assert shared_prompt =~ "open your PR against that branch"
    assert shared_prompt =~ "latest `ticket.N.branch.push` payload only to fetch the actual validated ref"

    assert stub_doc =~ "not a reason to park the whole ticket"
    assert stub_doc =~ "Do not reimplement ticket N's helper"
    assert stub_doc =~ "validated `ref` carried"
    assert stub_doc =~ "numeric topic key cannot recreate a readable title suffix"
    assert stub_doc =~ "stack on it"
    assert stub_doc =~ "If the branch push is irrelevant or unusable"
    assert stub_doc =~ "Stubs are local-only scaffolding"
    assert stub_doc =~ "Stop working on the dependent code only"
    assert stub_doc =~ "Required: emit `blocked` once"
    assert stub_doc =~ "Required: emit `unblocked` again"
    assert stub_doc =~ "commit and push the dependency before emitting readiness"
    assert stub_doc =~ "same validated `ref` and `sha`"
    assert stub_doc =~ "matching validated branch-push"
    assert stub_doc =~ "local pause generation"
    assert stub_doc =~ ~s|reason: "dependency", blocker_identifier: "N"|
    assert stub_doc =~ "publish the integrated commit before announcing readiness"
    assert stub_doc =~ "When you produce a dependency"
    assert stub_doc =~ "responsible for the readiness signal"
    assert stub_doc =~ "single-attempt fire-and-forget"
    assert stub_doc =~ "never infer readiness from the push alone"
    assert emit_doc =~ "ticket.N.agent.unblocked"
    assert emit_doc =~ "mid-turn checkpoint drain"
    assert emit_doc =~ "Do not infer readiness from `branch.push` alone"
    assert emit_doc =~ "required single-attempt, fire-and-forget emissions"
    assert shared_prompt =~ "Resume on explicit unblocked; inspect branch pushes"
    assert shared_prompt =~ "Never infer readiness from `branch.push` alone"
    assert repo_prompt =~ "explicit signal as readiness to consume"
    assert repo_prompt =~ "Never infer readiness from `branch.push` alone"
    assert repo_prompt =~ "remove temporary stubs"
    assert taxonomy =~ "keep unrelated prep moving"
  end

  # #1763: two agents staged a workpad body at `/tmp/wp_new.md`, the second write
  # won, and one ticket's workpad was published carrying the other's plan and PR
  # number. The `PATCH` returned 200, so only a body diff would have caught it.
  test "staging guidance keeps comment bodies out of the shared /tmp" do
    shared_prompt = one_line(File.read!(Path.join(@repo_root, "src/prompts/shared-agent-instructions.md")))
    repo_prompt = one_line(File.read!(Path.join(@repo_root, ".aiur/prompt.md")))

    assert shared_prompt =~ "Concurrent Aiur agents share the host's `/tmp`"
    assert shared_prompt =~ "`TMPDIR` already points at"
    assert shared_prompt =~ "Never write to a bare `/tmp/<generic-name>`"
    assert shared_prompt =~ "Verifying a comment write means diffing, not checking the status code"
    assert shared_prompt =~ "diff the returned body against the exact body you intended to publish"

    assert repo_prompt =~ "Stage every temporary file in a workspace-local path"
    assert repo_prompt =~ "Never write a GitHub comment or PR body to a bare `/tmp/<generic-name>`"
    assert repo_prompt =~ "For a comment body this means diffing, not checking the status code"
  end

  test "aiur run and status skill descriptions cover iarc and aiur triggers" do
    run_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-run/SKILL.md"))
    status_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-monitor/SKILL.md"))

    assert String.contains?(run_skill, "run IAR")
    assert String.contains?(run_skill, "run aiur")
    assert String.contains?(run_skill, "iarc run")
    assert String.contains?(status_skill, "iarc status")
    assert String.contains?(status_skill, "aiur status")
    assert String.contains?(status_skill, "aiurdev watch")

    for skill <- [run_skill, status_skill] do
      assert String.contains?(skill, "iarc")
      assert String.contains?(skill, "alias for `aiur`")
    end
  end

  test "Executor decision relay covers backend push, RC, and the Decisions log" do
    monitor_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-monitor/SKILL.md"))
    relay = File.read!(Path.join(@repo_root, ".claude/skills/aiur-monitor/references/alerts-and-decisions.md"))

    monitor_skill = one_line(monitor_skill)
    relay = one_line(relay)

    assert monitor_skill =~ "alerts-and-decisions.md"
    assert relay =~ "operator_decision:true"
    assert relay =~ "Decisions entry"
    assert relay =~ "Claude native push"
    assert relay =~ "Codex device notification"
    assert relay =~ "Remote Control"
    assert relay =~ "retry them on a later re-ask"
    assert relay =~ "matching resolution"
  end

  test "Executor protects a finite feature boundary" do
    monitor_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-monitor/SKILL.md"))
    run_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-run/SKILL.md"))
    executor = File.read!(Path.join(@repo_root, ".claude/skills/aiur-run/references/executor.md"))

    monitor_skill = one_line(monitor_skill)
    run_skill = one_line(run_skill)
    executor = one_line(executor)

    assert executor =~ "Protect convergence"
    assert executor =~ "Contained rework"
    assert executor =~ "P2/P3 non-blocker"
    assert executor =~ "creation exceeds completion"
    assert executor =~ "freeze new ticket creation"
    assert executor =~ "deferred findings ledger"
    assert run_skill =~ "prefer contained rework"
    assert monitor_skill =~ "completed versus created/promoted tickets"
  end

  test "needs-attention relay is an independent wake path for the Executor cadence" do
    monitor_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-monitor/SKILL.md"))
    run_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-run/SKILL.md"))
    relay = File.read!(Path.join(@repo_root, ".claude/skills/aiur-monitor/references/alerts-and-decisions.md"))

    monitor_skill = one_line(monitor_skill)
    run_skill = one_line(run_skill)
    relay = one_line(relay)

    assert monitor_skill =~ "streams new local-workspace alert records"
    assert monitor_skill =~ "workspace-less alerts remain visible"
    assert run_skill =~ "timer and alert path are additive"
    assert relay =~ "real-time wake path"
    assert relay =~ "does not replace the recurring status cadence"
  end

  test "agent operating guidance scopes local pre-PR verification to affected tests" do
    source =
      @repo_root
      |> Path.join(".claude/skills/using-aiur/dev-loop.md")
      |> File.read!()
      |> one_line()

    assert source =~ "pre-PR"
    assert source =~ "mix compile --warnings-as-errors"
    assert source =~ "mix format"
    refute source =~ "mix format --check-formatted"
    assert source =~ "affected tests only"
    assert source =~ "mix test --max-cases 4"
    refute source =~ "mix credo --strict"
    assert source =~ "Do not run Credo locally"
    assert source =~ "`make ci` is the authoritative full lint and full-suite gate"
    refute source =~ "mix dialyzer"

    assert source =~ "loop on unrelated suite flakes"
    assert source =~ "Re-run the scoped local pre-PR verification gate"
  end

  test "agent prompt delegates Credo to CI after inspecting lint settings" do
    repo_prompt = one_line(File.read!(Path.join(@repo_root, ".aiur/prompt.md")))

    assert repo_prompt =~ "before writing code read `src/.formatter.exs`"
    assert repo_prompt =~ "Credo's project settings in `src/mix.exs`"
    assert repo_prompt =~ "mix compile --warnings-as-errors"
    assert repo_prompt =~ "mix format"
    refute repo_prompt =~ "mix format --check-formatted"
    assert repo_prompt =~ "affected tests only"
    assert repo_prompt =~ "mix test --max-cases 4"
    refute repo_prompt =~ "mix credo --strict"
    assert repo_prompt =~ "Do not run Credo locally"
    assert repo_prompt =~ "authoritative full lint and full test suite through `make ci`"
    assert repo_prompt =~ "Do not gate PR-opening on a clean full-suite `mix test` run"
    assert repo_prompt =~ "Fix failures in this scoped gate"
  end

  test "agent PR guidance uses and verifies the configured integration branch" do
    dev_loop = one_line(File.read!(Path.join(@repo_root, ".claude/skills/using-aiur/dev-loop.md")))
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

  test "agent workflow hands final PR CI to ci-wait without a polling turn" do
    dev_loop = one_line(File.read!(Path.join(@repo_root, ".claude/skills/using-aiur/dev-loop.md")))
    turn_workflow = one_line(File.read!(Path.join(@repo_root, ".claude/skills/using-aiur/turn-workflow.md")))
    monitor = one_line(File.read!(Path.join(@repo_root, ".claude/skills/aiur-monitor/SKILL.md")))
    repo_prompt = one_line(File.read!(Path.join(@repo_root, ".aiur/prompt.md")))
    example_prompt = one_line(File.read!(Path.join(@repo_root, ".aiur/examples/prompt.md.example")))

    for source <- [dev_loop, turn_workflow, repo_prompt, example_prompt] do
      assert source =~ "agent:ci-wait"
      assert source =~ "Do not loop"
    end

    assert dev_loop =~ "keep the PR as a draft"
    assert dev_loop =~ "trust the delivered result without re-polling"
    assert dev_loop =~ "delivered failed-check names and excerpt"
    assert dev_loop =~ "run `gh pr checks` exactly once"
    assert dev_loop =~ "emit the required 100% progress sample"
    assert monitor =~ "Aiur.Events.GithubCiPoller"
    assert monitor =~ "expected, non-actionable idle state"
    assert monitor =~ "Do not keep or wake a worker turn just to poll `gh pr checks`"
  end

  test "CI-wait fallback config is documented but is not an init question" do
    config_reference =
      File.read!(Path.join(@repo_root, "website/docs-app/reference/configuration.md"))

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

  defp one_line(text), do: String.replace(text, ~r/\s+/, " ")
end

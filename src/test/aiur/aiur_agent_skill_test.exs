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
  @codex_exposed_aiur_skills ~w(aiur-agent aiur-build aiur-debug aiur-intro aiur-monitor aiur-run design-import)
  # `aiur-meta` is an Executor meta-check driven by `aiur-run`'s timer. It audits
  # operator surfaces and files tickets; issue workers never run it, so it stays
  # Claude-only and is deliberately not symlinked into `.codex/skills/`.
  @claude_executor_only_skills ~w(aiur-handoff aiur-meta release)

  # Every skill that can reach a ticket-creation command. Each states the rule
  # once, in a block located by this marker.
  @creation_rule_marker "same creation request"
  @creation_rule_docs ~w(
    .claude/skills/aiur-agent/conventions.md
    .claude/skills/aiur-run/SKILL.md
    .claude/skills/aiur-run/references/executor.md
    .claude/skills/aiur-meta/SKILL.md
    .claude/skills/aiur-build/SKILL.md
  )
  @label_token ~r/^[a-z][a-z0-9-]*(?::[a-z0-9-]+)?$/

  test "Claude backend surface: canonical skill dir exists with a SKILL.md" do
    assert File.dir?(@claude_skill)
    assert File.exists?(Path.join(@claude_skill, "SKILL.md"))
  end

  test "aiur-agent turn-workflow teaches respond-vs-code and PR-anchored mode" do
    content = File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/turn-workflow.md"))

    # respond-vs-code: reply by default, write code only when clearly intended
    assert content =~ "Most comments do not ask for code"
    assert content =~ "only make and push a code change when the comment clearly intends"

    # PR-anchored mode: work the PR's own branch, no new PR, no auto-resolve
    assert content =~ "PR-anchored mode"
    assert content =~ "you are already checked out on that PR's own branch"
    assert content =~ "Do NOT open a new PR"
  end

  test "aiur-agent requires explicit repository context for git commands" do
    content = File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/dev-loop.md"))

    assert content =~ "Never `cd` into a repository to run Git"
    assert content =~ "`git -C \"$workspace\"`"
    assert content =~ "absolute path"
    assert content =~ "`reset --hard`"
    assert content =~ "`clean -fd`"
    assert content =~ "`checkout -- .`"
    assert content =~ "`worktree remove`"
    assert content =~ "stop rather than fall back to the current directory"
    assert content =~ "rev-parse --path-format=absolute --git-path index.lock"

    overview = File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/overview.md"))
    assert overview =~ "`git -C \"$workspace\" ls-remote`"
  end

  test "issue-worker prompts require explicit repository context for git commands" do
    for path <- [".aiur/prompt.md", ".aiur/examples/prompt.md.example"] do
      content = File.read!(Path.join(@repo_root, path))

      assert content =~ ~s(workspace="$AIUR_AGENT_WORKSPACE")
      assert content =~ ~s(git -C "$workspace")
      assert content =~ "never `cd` into a repository to run Git"
      refute content =~ "Use `git` directly"
      refute content =~ "Read it with `git branch --show-current`"
    end
  end

  test "dictation guidance has one source shared by issue workers and Executors" do
    worker_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/SKILL.md"))
    executor_skill = File.read!(Path.join(@repo_root, ".claude/skills/aiur-run/SKILL.md"))
    guidance_path = Path.join(@repo_root, ".claude/skills/aiur-agent/dictated-input.md")
    guidance = File.read!(guidance_path)

    assert worker_skill =~ "dictated-input.md"
    assert executor_skill =~ "../aiur-agent/dictated-input.md"
    assert guidance =~ "Voice-originated text may render **Aiur**"
    assert guidance =~ "`A, your`"
    assert guidance =~ "never silently rewriting a real word or acronym"
  end

  # #1793: 29 tickets were filed with no `agent:*` label. Each was
  # undispatchable and invisible in every state-scoped view, so the fleet read
  # as having no work left. Every path that can file a ticket must state a
  # disposition, and the vocabulary it teaches has to be the vocabulary the
  # `gh` guard actually honours — a doc naming a label the guard refuses would
  # send agents into a wall, and a guard that stopped enforcing would leave the
  # docs describing a rule nothing applies.
  test "every filing path teaches a disposition the gh guard actually accepts" do
    documented =
      for path <- @creation_rule_docs, reduce: MapSet.new() do
        found ->
          per_doc =
            for block <- creation_rule_blocks(path), reduce: MapSet.new() do
              seen ->
                labels = documented_labels(block)

                # A creation rule that names no label is prose with no
                # vocabulary — the agent is told when, never what.
                assert MapSet.size(labels) > 0,
                       "#{path} states the creation rule without naming any label: #{block}"

                MapSet.union(seen, labels)
            end

          assert MapSet.member?(per_doc, "agent:todo"),
                 "#{path} never names `agent:todo` where it states the creation rule"

          MapSet.union(found, per_doc)
      end

    # Every label the skills teach must survive the guard, or following the
    # documented instruction fails.
    for label <- documented do
      assert run_creation_guard(["--title", "t", "--label", label]) == 0,
             "the gh guard refuses documented disposition #{label}"
    end

    # And the guard must actually be enforcing, not passing everything through.
    assert run_creation_guard(["--title", "t"]) != 0,
           "the gh guard admits an issue create with no disposition at all"

    assert run_creation_guard(["--title", "t", "--label", "wontfix"]) != 0,
           "the gh guard admits an issue create whose labels carry no disposition"

    assert MapSet.subset?(MapSet.new(~w(agent:todo needs-triage human:todo build-order)), documented),
           "the documented disposition vocabulary lost a case: #{inspect(MapSet.to_list(documented))}"
  end

  test "Codex backend surface: prompt-referenced skills resolve through symlinks" do
    for skill <- ~w(aiur-agent) do
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

  test "Command authoring assumes the operator has zero ticket context" do
    relay = File.read!(Path.join(@claude_skill, "emit-and-subscribe.md"))

    assert relay =~ "Assume the operator has zero context"
    assert relay =~ "The first line the operator reads is the `question`"
    assert relay =~ "state what each option causes"
    assert relay =~ "Name every referent"
    assert relay =~ "No answer:"
    assert relay =~ "under a minute"

    [_guidance, worked_example] = String.split(relay, "#### Before and after: a real Command from sandbox issue #101", parts: 2)
    [_, payload_json] = Regex.run(~r/```jsonc\n(.*?)\n```/s, worked_example)
    payload = Jason.decode!(payload_json)

    assert payload["question"] =~ "square 43 with direct multiplication or the integer-power helper?"
    assert payload["context"]["short_summary"] =~ "both options return 1849"
    assert payload["context"]["long_context_markdown"] =~ "`function_c/0`, the demo's final function"
    assert payload["context"]["long_context_markdown"] =~ "43 from `function_b/0`, the preceding ticket's function"

    options = Map.new(payload["options"], &{&1["id"], &1})
    assert options["multiply"]["description"] =~ "supporting powers other than two later would require changing the expression"
    assert options["power"]["description"] =~ "another integer exponent later becomes a one-argument edit"
    assert payload["recommendation"]["option_id"] == "multiply"
    assert payload["consequence_of_delay"] =~ "No answer: issue #101's agent remains paused"
    assert payload["consequence_of_delay"] =~ "no timeout chooses automatically"
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
      |> Path.join(".claude/skills/aiur-agent/dev-loop.md")
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
    dev_loop = one_line(File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/dev-loop.md")))
    turn_workflow = one_line(File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/turn-workflow.md")))
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

  # The rule block, not the whole file: a doc that merely mentions `agent:todo`
  # somewhere else must not satisfy the assertion. A paragraph that ends in a
  # colon carries its list with it.
  defp creation_rule_blocks(relative_path) do
    paragraphs =
      @repo_root
      |> Path.join(relative_path)
      |> File.read!()
      |> String.split(~r/\n[ \t]*\n/)
      |> Enum.map(&(&1 |> one_line() |> String.trim()))

    blocks =
      paragraphs
      |> Enum.with_index()
      |> Enum.filter(fn {text, _index} -> String.contains?(text, @creation_rule_marker) end)
      |> Enum.map(fn {text, index} ->
        # A paragraph that ends in a colon carries its list with it.
        if String.ends_with?(text, ":") do
          text <> " " <> Enum.at(paragraphs, index + 1, "")
        else
          text
        end
      end)

    assert blocks != [], "#{relative_path} no longer states the ticket-creation rule"

    blocks
  end

  defp documented_labels(block) do
    ~r/`([^`]+)`/
    |> Regex.scan(block)
    |> Enum.map(fn [_, token] -> token end)
    |> Enum.filter(&Regex.match?(@label_token, &1))
    |> MapSet.new()
  end

  # Runs the real wrapper the daemon installs on agent PATH, against a stub
  # `gh`, so this asserts the shipped guard rather than a copy of its rules.
  defp run_creation_guard(arguments) do
    root = Path.join(System.tmp_dir!(), "aiur-skill-guard-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    stub = Path.join(root, "gh")
    File.write!(stub, "#!/bin/sh\nexit 0\n")
    File.chmod!(stub, 0o755)

    try do
      {_output, status} =
        System.cmd(
          "/bin/sh",
          [Path.join(@repo_root, "src/priv/github_quota_guard.sh"), "issue", "create" | arguments],
          # This test asserts the dispatch disposition enforcement in
          # isolation. The shared GitHub budget broker lives beside the
          # installed wrapper, not beside the repo copy this test invokes, so
          # disable it explicitly or the admission check exits 75 whenever the
          # broker is absent (CI has no broker in `src/priv`).
          env: [
            {"AIUR_REAL_GH", stub},
            {"AIUR_REPO_STATE_PATH", Path.join(root, "state")},
            {"AIUR_GITHUB_BUDGET_ENABLED", "0"}
          ],
          stderr_to_stdout: true
        )

      status
    after
      File.rm_rf!(root)
    end
  end

  defp one_line(text), do: String.replace(text, ~r/\s+/, " ")
end

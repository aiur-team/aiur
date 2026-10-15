defmodule Aiur.AiurAgentSkillTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @claude_skill Path.join(@repo_root, ".claude/skills/aiur-agent")

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
    assert content =~ "This is a cross-skill override"
    assert content =~ "translate Git\nexamples from every other installed skill"
    assert content =~ "rev-parse --path-format=absolute --git-path index.lock"

    overview = File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/overview.md"))
    assert overview =~ "`git -C \"$workspace\" ls-remote`"
  end

  test "aiur-agent dev loop teaches collision-proof worktree paths and fail-loudly (#2362)" do
    content = File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/dev-loop.md"))

    # cross-skill override so the rule applies no matter how a CE skill frames worktrees
    assert content =~ "## Collision-proof worktrees"
    assert content =~ "cross-skill override"

    # the PR isolation scheme must carry a per-agent unique component, not just
    # the PR number, and must route through scripts/agent-worktree when present
    assert content =~ "a per-agent"
    assert content =~ "unique component"
    assert content =~ "pr-<n>-<unique>"
    assert content =~ "Two agents can legitimately review"
    assert content =~ "`scripts/agent-worktree create <n>`"

    # naming discipline alone is not the fix: the path is recomputed inline per
    # command, never persisted in a shared file (that was the rework lesson)
    assert content =~ "Never persist the worktree path in a file"
    assert content =~ "Recompute the path inline per command"
    assert content =~ "`scripts/agent-worktree path <n> --unique <component>`"

    # the worktree HEAD must be asserted before every mutation batch and drift
    # must abort loudly
    assert content =~ "Assert the worktree HEAD before every mutation batch"
    assert content =~ "`scripts/agent-worktree head-check <wt> <sha>`"
    assert content =~ "aborts loudly on\n  drift"

    # mutation testing requires a worktree, never the live checkout
    assert content =~ "Mutation testing requires a worktree"
    assert content =~ "Never run it in the live checkout"
    assert content =~ "A worktree is required, not optional"

    # an existing path is an error, never a reuse/repoint
    assert content =~ "An existing path is an error, not a reuse opportunity"
    assert content =~ "Never `git -C <existing-worktree> checkout <other-branch>`"
    assert content =~ "fresh unique"

    # stale worktrees must be pruned before creating
    assert content =~ "Prune stale worktrees before creating"
    assert content =~ "`git worktree prune`"
    assert content =~ "Never\n  remove a worktree another live agent is using"

    # the helper script itself carries the same guarantees
    helper = File.read!(Path.join(@repo_root, "scripts/agent-worktree"))
    assert helper =~ "#2362"
    assert helper =~ "refusing create"
    assert helper =~ "do not reuse or repoint"
    assert helper =~ "head-check"
  end

  test "aiur-agent dev loop audits the complete test tree for renames" do
    content = File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/dev-loop.md"))
    normalized = String.replace(content, ~r/\s+/, " ")

    assert content =~ "Renames and signature changes need an exhaustive test-tree audit"
    assert content =~ "rg -n --fixed-strings -- '<old-name>' src/test/"

    assert normalized =~
             "`test/aiur/github/` does not collect the sibling `test/aiur/github_client_test.exs`"

    assert content =~ "account for every hit"
  end

  test "aiur-agent push preflight validates the broker credential file (#2498)" do
    content = File.read!(Path.join(@repo_root, ".claude/skills/aiur-agent/dev-loop.md"))
    normalized = one_line(content)

    assert normalized =~ "Agent processes deliberately do not inherit `GITHUB_TOKEN` or `GH_TOKEN`"
    assert content =~ ~s(test -n "${AIUR_GITHUB_CREDENTIAL_FILE:-}")
    assert content =~ ~s(test -f "$AIUR_GITHUB_CREDENTIAL_FILE")
    assert content =~ ~s(test -s "$AIUR_GITHUB_CREDENTIAL_FILE")
    assert content =~ ~s(gh api user --jq .login)
    refute content =~ ~s(GH_TOKEN="$GITHUB_TOKEN" gh api user)

    # Each credential-preflight failure must identify the credential-file
    # authority and carry the actual file path where one is available.
    assert content =~ "AIUR_GITHUB_CREDENTIAL_FILE is unset; the agent GitHub credential file cannot be located"

    assert content =~
             "GitHub credential file is missing or empty: %s\\n' \"$AIUR_GITHUB_CREDENTIAL_FILE\" >&2"

    assert content =~
             "GitHub credential file could not authenticate: %s\\n' \"$AIUR_GITHUB_CREDENTIAL_FILE\" >&2"

    assert content =~ "GitHub credential file %s authenticates as %s; expected %s\\n'"
    assert content =~ ~s("$AIUR_GITHUB_CREDENTIAL_FILE" "$actual_login" "<bot_account>" >&2)

    # Budget holds are self-clearing pauses, not generic credential failures.
    assert content =~ "'aiur: github budget hold resource=core reset_at_ms='*|\\"
    assert content =~ "'aiur: github budget hold resource=graphql reset_at_ms='*)"
    assert content =~ ~s(printf '%s\\n' "$github_auth_output" >&2)

    budget_hold_guidance =
      "Follow the existing github_budget_hold pause.request protocol below; do not raise a credential attention."

    generic_credential_failure = "GitHub credential file could not authenticate"

    assert {budget_hold_index, _} = :binary.match(content, budget_hold_guidance)
    assert {generic_failure_index, _} = :binary.match(content, generic_credential_failure)
    assert budget_hold_index < generic_failure_index

    # Manual recovery clears GitHub-only inherited auth before installing the
    # credential-file helper; it must not fall back to scrubbed token variables.
    assert content =~
             ~r/-c credential\.https:\/\/github\.com\.helper= \\\n+\s+-c credential\.https:\/\/github\.com\.helper="\$agent_helper"/

    assert content =~ ~r/-c http\.https:\/\/github\.com\/\.extraheader= \\\n+\s+push origin HEAD/

    assert content =~ ~s(f="${AIUR_GITHUB_CREDENTIAL_FILE:-}")
    refute content =~ ~s(t=${GITHUB_TOKEN:-${GH_TOKEN:-}})

    assert normalized =~ "name `AIUR_GITHUB_CREDENTIAL_FILE` and its resolved path"
    assert normalized =~ "`supervisor_allowed` + `reversible`"
    assert normalized =~ "never `human_required` or `irreversible`"
  end

  test "aiur-agent instructions forbid --trace on a bare file or directory (#2311)" do
    for path <- [".claude/skills/aiur-agent/dev-loop.md", ".aiur/prompt.md"] do
      content = File.read!(Path.join(@repo_root, path))
      normalized = String.replace(content, ~r/\s+/, " ")

      assert Regex.match?(
               ~r/use `--trace` only with a specific `file:line`, never with a bare file or directory/i,
               normalized
             )

      assert normalized =~ "max_cases: 1"
    end
  end

  test "issue-worker prompts require explicit repository context for git commands" do
    for path <- [".aiur/prompt.md", ".aiur/examples/prompt.md.example"] do
      content = File.read!(Path.join(@repo_root, path))

      assert content =~ ~s(workspace="$AIUR_AGENT_WORKSPACE")
      assert content =~ ~s(git -C "$workspace")
      assert content =~ "never `cd` into a repository to run Git"
      assert content =~ "This rule overrides Git examples in every installed skill"
      refute content =~ "Use `git` directly"
      refute content =~ "Read it with `git branch --show-current`"
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

  test "agent guidance distinguishes GitHub budget holds from credential failures" do
    dev_loop = File.read!(Path.join(@claude_skill, "dev-loop.md"))
    taxonomy = File.read!(Path.join(@claude_skill, "event-taxonomy.md"))

    for text <- [dev_loop, taxonomy] do
      assert text =~ "github_budget_hold"
      assert text =~ "reset_at_ms"
    end

    assert dev_loop =~ "Do not emit a\n   credential attention"
    assert dev_loop =~ "resumes that pause automatically"
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

  test "Command authoring classifies routine reversible operations as delegable" do
    relay = File.read!(Path.join(@claude_skill, "emit-and-subscribe.md"))
    normalized = one_line(relay)

    assert normalized =~ "Classify the requested action, not the topic around it"
    assert normalized =~ "routine, reversible operational"
    assert normalized =~ "`authority: supervisor_allowed`"
    assert normalized =~ "irreversible actions, spend, external publication, or product direction"

    [_guidance, worked_example] =
      String.split(relay, "#### Before and after: a real Command from sandbox issue #101", parts: 2)

    [_, payload_json] = Regex.run(~r/```jsonc\n(.*?)\n```/s, worked_example)
    payload = Jason.decode!(payload_json)

    assert payload["authority"] == "supervisor_allowed"
    assert payload["reversibility"] == "reversible"
    assert Enum.all?(payload["options"], &(&1["risk"] == "low"))
    assert is_binary(payload["recommendation"]["option_id"])
  end

  test "Command authoring names the Executor-answerable Command types and the inverted burden" do
    relay = File.read!(Path.join(@claude_skill, "emit-and-subscribe.md"))
    normalized = one_line(relay)

    assert normalized =~ "Two Command types are explicitly Executor-answerable"
    assert normalized =~ ~s(kind: "rework_review")
    assert normalized =~ "authority: supervisor_preferred"
    assert normalized =~ ~s(kind: "sequencing")
    assert normalized =~ "explicitly declare `authority: human_required`"
    assert normalized =~ "omission now defaults to Executor-answerable"
    assert normalized =~ "within the Executor floor"
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

  defp one_line(text), do: String.replace(text, ~r/\s+/, " ")
end

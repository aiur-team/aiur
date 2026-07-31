---
title: "fix: gate PR-anchored watch dispatch on author trust (PR #687 blocker)"
type: fix
status: ready-to-implement
date: 2026-06-29
pr: 687
branch: feat/repo-wide-pr-comment-watch
closes_issue: 686
---

# Handoff: close the untrusted-comment dispatch hole in PR #687

## TL;DR for the next agent

PR #687 ("Repo-wide opt-in PR comment monitoring", branch `feat/repo-wide-pr-comment-watch`)
is **one fix away from merge-ready**. CI is green and the design is sound, but review found a
**blocking security hole**: on a PR carrying the `agent:watch` label (U2 trigger), an
**untrusted** GitHub user's comment dispatches a PR-anchored agent that treats the comment body
as instructions and can push to the branch. This is third-party prompt injection and it
contradicts the PR's own contract ("monitor all code-owner/**trusted** comments").

Your job: **add the author-trust gate to the PR-anchored watch dispatch path, add a regression
test that fails without the fix, and re-run `make all`.** Do the work on the existing branch
`feat/repo-wide-pr-comment-watch` (do not branch off main — this fixes that PR in place).

## Why it's broken (verified against the branch)

The trust gate is applied in the wrong place for the new path:

- `github_comments_poller.ex` `publish_comment/4` (~:298-312) stamps `author_trusted?` via
  `Sanitizer.stamp_author_trust/2` but **publishes every comment** on a watched PR
  (`bypass_contamination: true`). It does not filter by trust — it relies on a downstream gate.
- The only downstream trust gate, `trusted_comment_event?/1`, is consulted **exclusively inside
  the legacy rework path** — `transition_comment_issue_to_rework/3` in `orchestrator.ex`
  (~:997-1008) — and on the wake-priority path. It is `not trusted_comment_event?(event) ->
  {:skip, :untrusted_author}`.
- PR #687 adds `maybe_route_pr_anchored_or_legacy/5`, which **intercepts the comment BEFORE**
  the legacy rework transition. Its PR-anchored fork (`resolve_pr_anchored_unit/2` →
  `dispatch_pr_anchored_unit/4`) deliberately skips the rework state change and dispatches a
  synthetic `pr-watch` unit directly. It checks: PR is open, head ref is not `aiur/<n>`.
  **It never checks `author_trusted?`.**

Result for an `agent:watch` PR: `maybe_reactivate_on_comment` (no running entry) →
`maybe_route_pr_anchored_or_legacy` → `dispatch_pr_anchored_unit` → `do_dispatch_issue` — with
zero trust check. Any commenter wakes the agent.

Note: the **U3 one-off command path** (`/aiur` / bot-mention, via `PrCommandScanner` +
`publish_command_hits`) is **already safe** — it trust-filters *before* publishing, so only
trusted commands ever get published. This bug is specific to the **U2 watch-label** path, which
publishes everything and depends on a downstream gate that doesn't exist on the new fork.

## The fix

Gate the PR-anchored watch dispatch on event-time trust, mirroring what U3 already does. The
cleanest spot is the top of `maybe_route_pr_anchored_or_legacy/5` (so an untrusted comment falls
straight through to the unchanged legacy path and never triggers a `GET /pulls/N` fetch):

```elixir
defp maybe_route_pr_anchored_or_legacy(%State{} = state, issue_number, source, event, attempt) do
  if pr_anchored_routing_enabled?() and trusted_comment_event?(event) do
    case resolve_pr_anchored_unit(issue_number, event) do
      {:ok, %Issue{} = pr_issue} -> dispatch_pr_anchored_unit(state, pr_issue, source, event)
      :legacy -> maybe_transition_idle_issue_to_rework(state, issue_number, source, event, attempt)
    end
  else
    maybe_transition_idle_issue_to_rework(state, issue_number, source, event, attempt)
  end
end
```

Decisions to make while implementing:
- **Also apply `benign_review_pass_comment?/1`?** The legacy path skips dispatch on a bare
  "looks good"/approval review pass (`transition_comment_issue_to_rework` :1002-1003). Decide
  whether a benign review-pass comment on a watched PR should wake a PR-anchored agent. Recommend
  matching legacy behavior (skip it) unless there's a reason to differ — a watch agent waking to
  reply "yes it looks good" to an approval is noise.
- `trusted_comment_event?/1` already handles both atom and string `author_trusted?` keys
  (:1010-1012) — reuse it, don't reinvent.
- Keep the gate at routing time, not inside `dispatch_pr_anchored_unit/4`, so the untrusted path
  stays byte-for-byte legacy (no extra PR fetch, no log noise).

## The test (must fail before the fix)

In `src/test/aiur/orchestrator_deactivate_test.exs` (the U4 routing tests live ~:3969+), the
existing PR-anchored routing tests only exercise `author_trusted?: true`. Add a sibling that
asserts an **untrusted** commenter on an open human PR is **refused** PR-anchored dispatch:

- Set up the same open-human-PR routing event the happy-path test uses, but with
  `author_trusted?: false` (and `pr_watch` enabled).
- Inject `:pr_anchored_dispatch_fun` (the test seam already exists on the event) and assert it is
  **never called** — i.e. no PR-anchored agent is dispatched; the comment falls through to the
  legacy path instead.
- This test must fail against the current branch HEAD (proving it catches the hole) and pass
  after the gate is added.

## Validation

- From `src/`: `make all` (format, `credo --strict`, dialyzer, full suite, coverage > 85% gate).
- The 4 pre-existing `Aiur.CoreTest` agent-runner `assert_receive` timing flakes are known and
  not introduced by #687 (they fail identically on base `e6789bf`); don't chase them.

## Non-blocking follow-ups (optional, note in the PR — do NOT expand scope)

- `agent_runner.ex` was left unmodified vs. plan U4. The "PR-anchored unit never opens a new PR
  and never mutates `agent:*` labels" guarantee is currently asserted only via stubbed dispatch,
  not through the real `AgentRunner.run` path. Worth a follow-up test, not a merge blocker.
- `workspace.ex` `materialize_from_base/3` offline fallback checks out `pr_head_ref` at base HEAD
  rather than the PR commits — benign when fetch succeeds.
- `command_scan_newest_datetime/1` advances the cursor only over PR comments; a newer non-PR
  issue comment can stall the cursor and cause bounded re-scan waste.

## Context / sources

- PR: https://github.com/aiur-team/aiur/pull/687 — closes #686
- Plan (on the PR branch): `docs/plans/2026-06-26-001-feat-repo-wide-pr-comment-watch-plan.md`
- Key files: `src/lib/aiur/orchestrator.ex` (routing fork + `trusted_comment_event?/1`),
  `src/lib/aiur/events/github_comments_poller.ex` (`publish_comment/4`),
  `src/lib/aiur/events/pr_command_scanner.ex` (U3, already trust-safe — the pattern to mirror).

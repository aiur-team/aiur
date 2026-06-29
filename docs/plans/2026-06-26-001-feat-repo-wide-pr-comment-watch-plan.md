---
title: "feat: Repo-wide opt-in PR comment monitoring"
type: "feat"
date: "2026-06-26"
---

# feat: Repo-wide opt-in PR comment monitoring

## Summary

Let aiur act as a live review partner on PRs **across the whole repo it is pointed at** — not just the `aiur/<id>` PRs it created — but strictly opt-in. Two triggers: a persistent `agent:watch` PR label (monitor all code-owner/trusted comments) and a one-off per-comment command (`/aiur …` or a mention of the configured bot account) that needs no label. A triggered agent works the PR's **existing branch directly** (PR-anchored), differentiates respond-vs-code (replies by default; codes only when a change is clearly intended), replies on the exact review thread with the existing read-after-write verification, and does not auto-resolve. Detection is **poll-based** (the webhook is deferred — see Scope). Origin: `its-everdred/aiur#686` and `AIUR-COMMENT-WAKEUP-HANDOFF.md` (conversational brainstorm; no requirements doc).

---

## Problem Frame

aiur today is **issue-anchored**: it only reacts to comments on its own `aiur/<id>` PRs, and only when the owning ticket is `running` or `agent:human-review`. A code owner who comments on any other PR — including their own — gets no agent. The operator wants opt-in repo-wide watching so they can still leave human-directed suggestions freely on untagged PRs, but explicitly enroll a PR (label) or a single comment (command) for an agent to handle.

The architectural obstacle, surfaced by research: aiur derives a comment's owning ticket from the PR **head branch `aiur/<id>`** in multiple places (the firehose `translate/2`, `Client.fetch_open_pull_request_for_branch/2`, `GithubKeys.ref_to_topic`, `LsRemoteTicker`'s `refs/heads/aiur/*`). A watched PR on an arbitrary human branch is invisible to that resolution and falls through to PR-number topics nothing subscribes to. So the feature needs a **parallel PR-number identity** that leaves the legacy `aiur/<id>` flow intact.

---

## Scope Boundaries

### In scope
- Persistent watch via an `agent:watch` PR label; one-off via a `/aiur`/bot-mention comment command.
- Poll-based detection that extends the existing `GithubCommentsPoller` target set (no third poller).
- PR-number work-unit + comment-topic identity, parallel to `aiur/<id>`.
- PR-anchored agent execution (checkout + push the PR's existing branch; resume the same session per PR).
- Trust gate = CODEOWNERS ∪ `trusted_accounts` (event-time `author_trusted?`).
- Agent behavior: respond-vs-code differentiation; reply via the existing read-after-write core; no auto-resolve.
- Lifecycle: stop watching on merge/close/untag; tear down PR-anchored workspaces.

### Deferred to Follow-Up Work
- **GitHub webhook receiver** (HMAC `X-Hub-Signature-256` verification + reachable bind) as a *latency optimization* over polling. Net-new public surface: aiur's HTTP server is loopback-only by default and off in `--bg`/headless, and a webhook can't reuse the same-origin/CSRF write pipeline. Its own plan once the poll-based core lands. (Operator decision 2026-06-26: "punt the webhook and stick to poll.")
- Broadening the bounded command-scan (see U3) to unbounded repo-wide if the cap proves too tight.

### Non-goals
- Auto-resolving review threads (operator: only when explicitly instructed).
- Acting on comments on **untagged** PRs absent a per-comment command (strict opt-in — human-directed notes must pass through untouched).
- Changing the legacy `aiur/<id>` agent-created-PR comment flow.

---

## Key Technical Decisions

1. **Poll-authoritative; webhook deferred.** The codebase's hard-won posture (HANDOFF #408/#580) is "the firehose lies; the direct poller is truth." The poller runs headless with per-target cursors and error isolation; the webhook adds reachability/HMAC/loopback constraints with the same at-most-once risk. Build on the poller; defer the webhook.
2. **PR-number identity, parallel to `aiur/<id>`.** Watched/commanded PRs are keyed by PR number for both the comment topic (`ticket.<pr#>.pr.review_comment`) and the running-entry identifier. The `aiur/<id>` branch-derivation paths are left intact for legacy agent PRs and **bypassed** (not modified) for watched PRs by passing the PR object through (`open_pull_requests_by_target` already exists in the poller).
3. **Reuse the battle-tested cores, don't rebuild.** `Client.reply_to_review_thread/3` (read-after-write verify), the `GithubCommentsPoller` per-target `since`-map + `all_comment_targets_failed?` isolation, and the `author_trusted?` CODEOWNERS gate (`Sanitizer.stamp_author_trust/2` ∪ `bot_account`/`trusted_accounts`) are reused as-is.
4. **Extend the poller's target set; do not add a third poller.** Mirror `human_review_comment_poll_targets/2` (`orchestrator.ex:1350`) with a watch-target source; ride the existing `GithubCommentsPoller`.
5. **Respond-vs-code is a judgment call taught in the skill, not a code classifier.** Most comments want a reply, not code. The differentiation lives in the `using-aiur` skill text (extending the existing "PR review feedback loop" section), not a heuristic in Elixir.
6. **No auto-resolve.** Reply and resolve are separate `client.ex` operations; the watched-PR path wires only the reply (read-after-write) path, never `resolve_review_thread`.

---

## High-Level Technical Design

*This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

**Identity scheme (the load-bearing decision):**

| Surface | Legacy (unchanged) | Watched/commanded PR (new) |
|---|---|---|
| Work-unit identifier | tracker issue id `<id>` | PR number `<pr#>` |
| Comment topic | `ticket.<id>.pr.review_comment` | `ticket.<pr#>.pr.review_comment` |
| PR→work resolution | head ref `aiur/<id>` → id | PR object passed through (no branch derivation) |
| Git branch in workspace | `git checkout -B aiur/<id>` | `git checkout <pr_head_ref>` (track remote) |
| Workspace leaf | `<root>/<owner>/<repo>/<id>/` | `<root>/<owner>/<repo>/pr-<pr#>/` |

**Detection → dispatch flow (poll cycle):**

```
:run_poll_cycle → run_github_polls (orchestrator.ex:1559)
  └─ poll_github_comments → github_comment_poll_targets (orchestrator.ex:1330)
       ├─ running_comment_poll_targets        (existing)
       ├─ human_review_comment_poll_targets   (existing)
       ├─ watch_comment_poll_targets          (NEW · U2 — open PRs labeled agent:watch, keyed by pr#, PR passed through)
       └─ pr_command_scan                     (NEW · U3 — recently-updated open PRs, /aiur or @bot, trust-gated)
  → GithubCommentsPoller.poll → publishes ticket.<pr#>.pr.review_comment (bypass_contamination for command hits)
  → orchestrator maybe_reactivate_on_comment (orchestrator.ex:589)
       ├─ find_running_by_identifier(pr#)  → resume same session (continuity)
       └─ no entry → dispatch PR-anchored work unit (U4 — synthetic unit from the PR, NOT a label flip)
  → agent in PR-anchored workspace; respond-vs-code (U5); reply via Client.reply_to_review_thread (read-after-write)
```

Trust gate (`author_trusted?`, `sanitizer.ex:102`) is applied at event time for both triggers; `Publisher.bot_self_loop?/1` (`publisher.ex:182`) still drops the bot's own comments while a human's mention of the bot passes (it keys on the comment author).

---

## Implementation Units

### U1. Config, `agent:watch` label, and trust scaffolding

**Goal:** Recognize the `agent:watch` PR label, add the watch-feature config, and ensure `bot_account` + `trusted_accounts` are set (the reply verify compares against `bot_account`; the trust gate unions `trusted_accounts`).

**Requirements:** Foundation for both triggers (origin #686). Read-after-write verify and the trust gate both fail closed when `bot_account`/`trusted_accounts` are unset — and they are currently unset in `.aiur/config`.

**Dependencies:** none.

**Files:**
- `src/lib/aiur/github/labels.ex` — add `watch` to the slug list (`labels.ex:26`); `agent:watch` is a **marker label, not a dispatch state** (it must not enter the active-state lifecycle).
- `src/lib/aiur/config/schema.ex` — add a `pr_watch` block (`enabled` bool, `watch_label` default `"watch"`, command config); confirm `bot_account`/`trusted_accounts` (`schema.ex:49-50`).
- `src/lib/aiur/github/config.ex` — accessors for the new fields (with `@spec`).
- `.aiur/config` — set `bot_account`, `trusted_accounts`, and the `pr_watch` block (example values).
- `SPEC.md` — document the opt-in watch/command feature (keep aligned per `AGENTS.md:15-19`).
- `src/test/aiur/config_test.exs`, `src/test/aiur/github/labels_test.exs` (or nearest existing).

**Approach:** `agent:watch` slots into the `<prefix>:<slug>` scheme but is excluded from the active-state set used for dispatch — it only marks "poll this PR's comments." Config goes through `Aiur.Config` (no ad-hoc env reads, `AGENTS.md:20`).

**Patterns to follow:** `labels.ex:26` slug list; `schema.ex:49-50` field defs; `config.ex` accessor style.

**Test scenarios:**
- Happy: the label builder produces `agent:watch`; config parses a `pr_watch` block; accessors return the watch label + `enabled`.
- Edge: missing `pr_watch` block → feature disabled (default), no crash.
- Edge: `bot_account` unset → accessor returns nil and callers can detect the misconfig (don't silently pass).
- `Test expectation`: behavioral for the accessors/parsing; the label-string assertion is a pure unit test.

**Verification:** `agent:watch` recognized; config loads with and without the block; `mix specs.check` passes for new public functions.

---

### U2. Watch-target discovery + PR-number identity (poll)

**Goal:** Each poll cycle, discover open PRs labeled `agent:watch` repo-wide and feed them into `GithubCommentsPoller` as **PR-number-keyed** targets carrying their PR object, so the poller never branch-derives.

**Requirements:** Persistent-watch trigger; poll-authoritative detection; per-target cursor/error isolation; PR-number identity (origin #686; Key Decision 2).

**Dependencies:** U1.

**Files:**
- `src/lib/aiur/github/client.ex` — new `fetch_open_pull_requests_by_label/2` (open PRs carrying the watch label; reuse the `request_fun`-injectable pattern; `@spec`).
- `src/lib/aiur/orchestrator.ex` — `watch_comment_poll_targets/2` mirroring `human_review_comment_poll_targets/2` (`:1350`); union it into `github_comment_poll_targets/2` (`:1330`); pass each PR via the `open_pull_requests_by_target` opt so the poller skips `fetch_open_pull_request_for_branch`.
- `src/lib/aiur/events/github_comments_poller.ex` — confirm `target = pr#` publishes `ticket.<pr#>.pr.review_comment` and consumes the passed PR (`:180`); bound the set (cap per poll, mirror the 25-cap).
- `src/test/aiur/events/github_comments_poller_test.exs`, `src/test/aiur/orchestrator_*` (poll-target tests).

**Approach:** A watched PR's identifier/topic is its PR number. Reuse the per-target `since` map (advance only on zero errors; the deliberate −1s rewind) and `all_comment_targets_failed?` so one flaky watch PR never stalls the set. Exclude closed/merged PRs at the query.

**Patterns to follow:** `human_review_comment_poll_targets/2` (`orchestrator.ex:1350`); `merge_comment_cursors`; `open_pull_requests_by_target` (`github_comments_poller.ex:180`); the label query at `client.ex:964`.

**Test scenarios:**
- Happy: a PR labeled `agent:watch` becomes a target keyed by its PR number; a review comment on it publishes `ticket.<pr#>.pr.review_comment`.
- Integration: the passed PR is used — **refute** any `fetch_open_pull_request_for_branch` call for watched targets.
- Edge/isolation: per-target cursor advances only on success; one failing watch target does not stall or rewind the others (only `all_comment_targets_failed?` escalates).
- Edge: closed/merged watch PRs are excluded; the target set is capped at the per-poll limit (log what's dropped).

**Verification:** watch-labeled PR comments arrive at the orchestrator as `ticket.<pr#>` events with no branch derivation; isolation preserved.

---

### U3. Per-comment command scanner (poll)

**Goal:** Detect a one-off command (`/aiur …` or a mention of `github.bot_account` — never `@aiur`, a real user) on **any** open PR comment with no label required, gate by author trust, and emit the PR-number reactivation event.

**Requirements:** One-off command trigger; trust gate (CODEOWNERS ∪ `trusted_accounts`); coexist with bot-self-loop; one-and-done (origin #686).

**Dependencies:** U1, U2 (PR-number topic identity).

**Files:**
- `src/lib/aiur/events/pr_command_scanner.ex` (new pure module — parse the command marker; high coverage expected) **or** an extension of the poller; decide during implementation.
- `src/lib/aiur/orchestrator.ex` — wire the scan into the poll cycle, bounded to recently-updated open PRs (per-target cursor + cap).
- `src/lib/aiur/events/publisher.ex` — emit with `bypass_contamination: true` (`:77-84`); confirm `bot_self_loop?/1` (`:182`) coexistence.
- `src/lib/aiur/events/sanitizer.ex` — reuse `author_trusted?` (`:102`); no change expected.
- `src/test/aiur/events/pr_command_scanner_test.exs`, `src/test/aiur/orchestrator_*`.

**Approach:** Scan recently-updated open PRs (bounded + cursored) for a leading `/aiur` or a `@<bot_account>` mention. Act only when `author_trusted?`. On a match, publish the PR-number reactivation topic with `bypass_contamination: true` so it dispatches even though the PR is not in the tracked set. One-off: a command triggers a single dispatch and stores no persistent watch state (label = persistence; command = one-shot).

**Patterns to follow:** the firehose `bypass_contamination` path (`publisher.ex:77-84`); `bot_self_loop?/1` (`publisher.ex:182`); `author_trusted?` (`sanitizer.ex:102`); the per-target cursor.

**Test scenarios:**
- Happy: `/aiur fix the nil case` by a code owner on an unlabeled PR emits the reactivation event; a `@<bot_account>` mention by a `trusted_accounts` user triggers.
- Trust-deny: the same command by an untrusted author is ignored (no event).
- Self-loop: the bot's own comment containing the marker is dropped (no dispatch).
- Negative: a normal comment with no marker on an unlabeled PR does **not** trigger (strict opt-in).
- One-off: a single command produces exactly one dispatch and no persistent watch target on the next cycle.
- Edge: scan is bounded — assert the cap and that skipped PRs are logged, not silently dropped.

**Verification:** a trusted `/aiur`/bot-mention on any open PR wakes an agent; untrusted/no-marker comments never do.

---

### U4. PR-anchored workspace + dispatch

**Goal:** Run the agent against the PR's **existing head branch** (checkout + push there), keyed by PR number, for watched/commanded PRs — bypassing `aiur/<id>`. Reactivation resumes the same session per PR.

**Requirements:** PR-anchored work anchor; session continuity (origin #686); the heaviest architectural change.

**Dependencies:** U2, U3.

**Files:**
- `src/lib/aiur/workspace.ex` — a `checkout_existing_pr_branch` variant of `checkout_fresh_branch/1` (`:134`) doing `git fetch origin <pr_head_ref>` + `git checkout <pr_head_ref>`; `branch_for/1` (`:172`) no longer the sole branch authority; workspace leaf `pr-<pr#>` (`issue_workspace_path/2:668`).
- `src/lib/aiur/orchestrator.ex` — a PR-anchored dispatch path: construct a synthetic work unit from the PR (number, title, body, head ref) and dispatch **without** an `agent:rework` label flip (no tracker issue exists); running-entry `:identifier = pr#`; `find_running_by_identifier` (`:6026`) matches it for resume.
- `src/lib/aiur/agent_runner.ex` — the lock path (`:595`) assumes `aiur/<id>`; PR-anchored variant.
- `src/lib/aiur/github/client.ex` — pass the PR through; bypass `fetch_open_pull_request_for_branch` (`:508`).
- `src/test/aiur/orchestrator_deactivate_test.exs` (reactivation/resume), `src/test/aiur/workspace_*` (if present; else a new pure test for the branch-derivation helper).

**Approach:** The workspace checks out the remote PR branch instead of creating `aiur/<id>`, keyed by `pr-<pr#>` under the configured root (honor workspace-safety, `AGENTS.md:27-29` — never cwd the source repo). Dispatch builds a PR-anchored unit; the legacy `aiur/<id>` path is untouched. Reactivation indexes by PR number so a follow-up comment resumes the same session (codex `exec resume`).

**Execution note:** Characterization-first — add coverage pinning the existing `aiur/<id>` workspace/branch path **before** introducing the PR-anchored variant, so the legacy path is provably unchanged.

**Patterns to follow:** `checkout_fresh_branch/1` (`workspace.ex:134`); `materialize_from_base/2` (`:109`); `dispatch_issue/4` (`orchestrator.ex:3182`); `find_running_by_identifier` (`:6026`).

**Test scenarios:**
- Happy: a watched-PR dispatch checks out the PR's head ref (assert no `git checkout -B aiur/...`); workspace leaf is `pr-<pr#>` under the configured root.
- Identity/resume: a second comment on the same PR resolves to the existing running entry (resume, not a new dispatch).
- Legacy no-regression: a tracker-issue dispatch still uses `aiur/<id>` and `fetch_open_pull_request_for_branch` unchanged.
- Safety: the agent cwd is the materialized workspace, never the source repo (mirror existing workspace-safety assertions).
- Edge: a watched PR whose head branch is on a fork (if reachable) — document behavior or explicitly out-of-scope.

**Verification:** an agent for a watched PR operates on the PR's branch; follow-up comments resume the session; the legacy path is byte-for-byte unchanged in tests.

---

### U5. Agent behavior — respond-vs-code + PR-anchored mode (skill text)

**Goal:** Teach the agent to reply by default and code only when a change is clearly intended, and to operate in PR-anchored mode (already on the PR branch; push there; reply on threads; no new PR; no auto-resolve).

**Requirements:** The headline behavioral rule (origin #686, "differentiate respond-vs-code — a common failure mode"); PR-anchored execution semantics; reuse read-after-write + no-resolve.

**Dependencies:** U4.

**Files:**
- `.claude/skills/using-aiur/turn-workflow.md` — extend `## PR review feedback loop` (`:35-56`), which already differentiates change-request vs reply-only and mandates `aiur_reply_review_thread` (read-after-write) + no auto-resolve.
- `.claude/skills/using-aiur/conventions.md` — the trusted-author gate already lives here (`:1-22`); cross-reference.
- `src/prompts/shared-agent-instructions.md` — a short PR-anchored-mode pointer (always visible) if the workflow section is insufficient.
- `src/test/aiur/aiur_agent_skill_test.exs` — skill-content assertions (the `.codex/skills/using-aiur` symlink carries the same text to codex).

**Approach:** Add to the existing section: (a) "Most comments just want a response — a question, a clarification, a discussion. Reply on the thread. Only write/push code when a change is clearly intended." (b) PR-anchored mode: "For a watched/commanded PR you are already on the PR's branch — push commits there, reply on the threads, do NOT open a new PR, do NOT resolve threads unless explicitly told."

**Patterns to follow:** the existing `## PR review feedback loop` framing (`turn-workflow.md:35-56`); `conventions.md` trust section; the `aiur_reply_review_thread` tool contract.

**Test scenarios:**
- `Test expectation`: skill-content test asserting the respond-vs-code and PR-anchored-mode guidance strings are present (mirror `aiur_agent_skill_test.exs`). The behavioral differentiation is a judgment call with no Elixir code path, so coverage is on the skill text's presence, not runtime behavior.

**Verification:** the skill instructs respond-vs-code + PR-anchored mode; the codex symlink resolves to the same content.

---

### U6. Lifecycle / teardown

**Goal:** Stop watching a PR on merge/close/untag; tear down the PR-anchored workspace + running entry on terminal; the one-off command leaves no persistent state.

**Requirements:** Lifecycle; strict opt-in (untag stops watching) (origin #686).

**Dependencies:** U2, U4.

**Files:**
- `src/lib/aiur/orchestrator.ex` — ensure the U2 watch query excludes closed/merged/unlabeled (target naturally drops); tear down an active PR-anchored agent whose PR closes/merges/untags mid-run (mirror `terminate_running_issue` / `maybe_stop_active_agents_on_default_branch_push`).
- `src/lib/aiur/workspace.ex` — cleanup for `pr-<pr#>` workspaces.
- `src/test/aiur/orchestrator_*`.

**Approach:** Most teardown is implicit (a merged/closed/untagged PR leaves the watch target set → no more polling). The explicit work is terminating an in-flight PR-anchored agent when its PR reaches a terminal state and cleaning its workspace; the command path stores nothing to clean.

**Patterns to follow:** existing terminal/teardown (`terminate_running_issue`); the default-branch-push stop path.

**Test scenarios:**
- Happy: a watch PR that merges drops from the next cycle's target set.
- Untag-stops: removing `agent:watch` stops polling that PR.
- Teardown: an active PR-anchored agent whose PR closes mid-run is terminated and its workspace cleaned (no orphan `pr-<pr#>`).
- One-off: a command dispatch leaves no watch target on subsequent cycles.

**Verification:** closing/merging/untagging a watched PR stops the watch and cleans up; no orphaned PR-anchored workspaces.

---

## Risk Analysis & Mitigation

- **R1 — `aiur/<id>` assumption leakage (highest).** A watched PR routed through a branch-derivation path lands on a PR-number topic nothing subscribes to. *Mitigation:* the PR-anchored path **bypasses** (never modifies) `firehose.translate/2`, `fetch_open_pull_request_for_branch`, `GithubKeys.ref_to_topic`, and `LsRemoteTicker`; U4's characterization test pins the legacy path; U2 refutes branch-derivation for watched targets.
- **R2 — command-scan cost.** Scanning open PRs every cycle scales with repo activity. *Mitigation:* bound to recently-updated open PRs, per-target cursor, hard cap per poll, and **log** what's dropped (no silent truncation).
- **R3 — trust fail-closed misconfig.** `bot_account`/`trusted_accounts` are currently **unset**; reply-verify and the gate fail closed (silent "nothing happens"). The repo CODEOWNERS uses `*`, so event-time trust equals the co-owner definition. *Mitigation:* U1 sets and documents both; surface a clear misconfig signal rather than passing nil silently; flag the `*` CODEOWNERS breadth to the operator.
- **R4 — re-opening the `issue.commented` scope boundary.** The team deliberately excluded PR-body comments as a reactivation trigger for legacy PRs; respond-vs-code needs both review-thread and conversation comments. *Mitigation:* include both **only** for the new PR-number topics; leave the legacy `aiur/<id>` exclusion intact; test the distinction.
- **R5 — workspace safety.** PR-anchored checkout must stay under the configured root, never the source repo (`AGENTS.md:27-29`). *Mitigation:* reuse `issue_workspace_path/2` derivation; assert cwd safety.

---

## System-Wide Impact

Touches the orchestrator poll cycle (new target source + command scan), the comment-poller (PR-number targets), the workspace/branch model (PR-anchored checkout — the deepest change), the agent prompt/skill text, and config (`agent:watch` label + `pr_watch` block). The legacy `aiur/<id>` agent-created-PR flow is explicitly unchanged. Affected parties: operators (new opt-in surface + the CODEOWNERS/`bot_account` config they must set), and agents (new PR-anchored execution mode).

---

## Deferred / Open Implementation Notes

- Webhook receiver (HMAC + reachable bind) — separate follow-up plan (Scope: Deferred).
- Exact `pr_command_scanner` home (new module vs poller extension) — decide at implementation; favor a pure module for coverage.
- Fork-head watched PRs — confirm or explicitly scope out during U4.
- The synthetic-work-unit shape for a PR with no tracker issue (struct vs a minimal `Issue`) — settle when wiring U4 dispatch against `dispatch_issue/4`.

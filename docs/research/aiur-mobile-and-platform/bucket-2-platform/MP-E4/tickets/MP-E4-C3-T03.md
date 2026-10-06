---
ticket_id: MP-E4-C3-T03
feature_id: MP-E4
chunk_id: MP-E4-C3
bucket: 2-platform
title: "Causal anchors: git push, gh pr create and gh pr merge command entries"
status: blocked
blocked_by: [DESIGN-E4, MP-E4-C3-T02]
prior_units: [U6]
prior_boundaries: [PRJ, BUS]
prior_features: []
prior_findings: [RQ-E4-2 (resolved below with a census); contract conversations-transcripts-anchors §10]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C3-T03 — Causal anchors for pushes and PRs

## Identity and outcome

- Bucket 2 · MP-E4 · C3 · T03.
- **User value:** "Pushed abc1234", "PR opened" and "PR merged" jump to the
  command that caused them, not to "about here" (brief §5 jump points).
- **Deliverable:** `Anchors.causal/2` (pure rule table) and its call in
  the resolver before `position/3`.
- **Non-goals:** anchoring `git commit` (not an event; contract §10 note).

## Dependencies and blockers

- DESIGN-E4; MP-E4-C3-T02.
- Concurrent with: C4-T01.

## Verified starting point

- Command entries keep `body` = command, `output`, `meta.exit_code` (T01
  mapping of `codex/transcript.ex:122-145`).
- Event payloads: `branch.push` → `%{ref, sha}` (`events/ls_remote_ticker.ex:168-183`,
  polled every 30 s, `:4`); `pr.opened` / `pr.merged` → `%{action, pr,
  timestamp}` where `pr` is GitHub's pull_request map (`pr["number"]`,
  `pr["head"]["sha"]`; `events/github_firehose.ex:392-411`). Webhook-sourced PR
  events must be checked at pickup for the same shape (fixture for each).
- **RQ-E4-2 census (2026-10-06, read-only, 378 workspace `agent.ndjson` files
  under `~/code/aiur-workspaces`, Codex `commandExecution` items):**

| Command | Seen | exit 0 | Output carries the matching key |
| --- | --- | --- | --- |
| `git push` | 563 | 461 | 241 a `<old>..<new>` sha range; 218 `[new branch]` (459 of 461) |
| `gh pr create` | 167 | — | 137 a `/pull/<n>` URL (exit 0) |
| `gh pr merge` | 17 | 14 | number in the command or output (rule below) |

  IssueLog cannot be used for this: its command records keep no payload
  (45,498 of 45,498 command records have `payload: null`), so output and exit
  code are only in the workspace log and, later, in the journal.

## Chosen design

Rule table (all require exit code 0 and an entry `observed_at` within
`[event.observed_at − 10 min, event.observed_at]`; the window covers the 30 s
push poll and webhook delays with margin):

| Event | Command regex on `body` | Key match in `output` (or command) | Method |
| --- | --- | --- | --- |
| `push` | `(^|[;&|(]\s*|\s)git\s+push\b` | range `([0-9a-f]{7,40})\.\.\.?([0-9a-f]{7,40})` whose second sha is a prefix of event `sha`; or `[new branch]` line whose branch equals the event `ref` without `refs/heads/` | `command_text` |
| `pr_opened` | `\bgh\s+pr\s+create\b` | `/pull/(\d+)` equals `pr["number"]` | `command_text` |
| `pr_merged` | `\bgh\s+pr\s+merge\b` | `\bgh\s+pr\s+merge\s+#?(\d+)` or `/pull/(\d+)` equals `pr["number"]`; a bare `gh pr merge` with no number is not matched | `command_text` |

- Several candidates → the latest `pos`. No key match → no causal anchor (the
  resolver falls through to `observed`). A causal anchor is never created from
  time proximity alone.
- `placement: "at"`, `precision: "causal"`.
- Executor merges: the same rule runs on the Executor conversation (MP-E3), so
  one `pr.merged` can anchor `observed` in the worker and `causal` in the
  Executor conversation (contract §10).

## Implementation steps

1. `Anchors.causal(event, entries)` with the table above as data
   (module attribute), each rule a `{kind, command_regex, key_fun}`.
2. Resolver: for kinds `push`, `pr_opened`, `pr_merged`, call `causal/2` on the
   window before `position/3`; for the Executor conversation too when one exists.
3. Measurement step in the PR (RQ-E4-2 false-positive rate): run the rule table
   over the census population with a small read-only script (same pattern as
   MP-E4-C1-T00: aggregates only), pairing each matched push with the branch's
   actual push events where available; report matches, ambiguous (> 1 candidate)
   and zero-key cases with date and population.

## Non-happy paths

- **Force push** (`+old...new`): the regex accepts `...`; the second sha is the
  new head.
- **Output truncated** by the 64 KiB bound: git and gh print the key in the
  last lines; T01 keeps the tail 16 KiB, so the key survives.
- **Push of a different branch** in the same window: the sha or branch must
  match, so it is not anchored.
- **`gh` guard wrapper** in agent workspaces still records the command text as
  the agent typed it (the transcript is the provider's view); the regex keys on
  that text.
- **Claude workers:** a Bash `tool_use` becomes a `command` entry with empty
  output (`claude/transcript.ex:273-283`), and its output arrives later as a
  separate `tool_result` entry (`tool: "result"`, `is_error` instead of an exit
  code, `claude/transcript.ex:307-320`). The rule joins the two: the command
  entry supplies the regex match and `pos`; the `tool_result` with the same
  `refs.tool_call_id` (Claude `tool_use_id`) supplies the output and success
  (`is_error` false stands in for exit 0). Fixture from a Claude transcript.

## Compatibility and rollout

- Pure addition; observed anchors already exist for these events, so causal
  ones appear as stronger lines. Rollback: revert.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur/conversation/anchors_causal_test.exs \
  test/aiur/conversation/anchor_resolver_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "push range end matches event sha" | causal `at` the command entry | range rule |
| "[new branch] matches by branch name" | causal | new-branch rule |
| "push of another sha in window is not causal" | observed | key match requirement (mutation: drop the sha check → fails) |
| "gh pr create URL number matches" | causal | URL rule |
| "bare gh pr merge without number is not causal" | observed | the number requirement |
| "exit code 1 never causal" | observed | exit check |
| "command older than 10 min is not causal" | observed | window |
| "Claude Bash command + later tool_result with git push output" | causal `at` the command entry | the command/result join |
| "webhook-shaped pr.merged payload" | causal | payload accessor fallbacks |

## Completion and handoff

- [ ] Tests green; PR body has the false-positive census with date and size.
- Dependents: MP-E4-C4-T01 (labels), MP-E4-C5-T03 (precision display).
- Docs: none here.

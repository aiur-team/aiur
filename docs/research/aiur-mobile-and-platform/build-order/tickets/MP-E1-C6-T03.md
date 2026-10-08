---
ticket_id: MP-E1-C6-T03
feature_id: MP-E1
chunk_id: MP-E1-C6
bucket: 2-platform
title: aiur queue recover and clear --remove-markers (rollback runbook)
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C6-T02, MP-E1-C3-T07]
prior_units: [U6]
prior_boundaries: [CLI #31]
prior_features: []
prior_findings: [MP-E1 F1]
size_owner: "CLI (aiur-engine.sh); provisional, RC-23"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C6-T03 — Recovery and rollback verbs

> **Plan refresh (wave 0).** Same guard and engine arm as C6-T02.

## Identity and outcome

- Bucket 2, MP-E1, C6, T03. Plan §6 Restart recovery, §8 Risks.
- **User value:** a lost store is rebuilt from GitHub, and a downgrade to a
  release without the marker is safe.
- **Deliverable:** `aiur queue recover` (calls `Aiur.BuildQueue.recover/0`,
  C3-T07) and `aiur queue clear --remove-markers` (dequeues every item, removes
  the marker from every open issue carrying it, paced by
  `max_writes_per_minute`, then empties the store).

## Dependencies and blockers

- DESIGN-E1 (copy, confirmation wording), C6-T02 (guard), C3-T07.

## Verified starting point (`45a290e3`)

- Without the marker registration a release parses `agent:queued` as a state
  (`github/issues.ex:1176-1187`) and denies `queued + todo`
  (`github/dispatch_authorization.ex:51-53`) — the reason the runbook exists.
- `remove_label/2` 404 = success (`github/issue_state.ex:80-82`).

## Chosen design

- `clear --remove-markers` requires `--yes` (non-interactive safe). It removes
  the marker only; any `agent:todo` stays (the item becomes an ordinary todo
  ticket, which a pre-queue release understands). Uses the intent protocol so
  a crash mid-clear resumes.
- `recover` refuses when the store is healthy unless `--force` (it would drop
  order and edges).

## Implementation steps

1. Engine sub-verbs + flags; `AgentControlCLI.queue/1` routes.
2. Server `clear/1` executor (unmark actions).
3. Docs: `reference/cli.md`; a "Downgrading" note in
   `concepts/ticket-lifecycle.md` queue section (C9-T02 may host it).

## Non-happy paths

Budget hold mid-clear → `writes_paused`; re-running continues.

## Compatibility and rollout

Operator-only.

## Verification

| Test | Expected | Fails without |
| --- | --- | --- |
| `src/test/aiur/build_queue/clear_test.exs` (PROPOSED) "clear removes markers from open issues and keeps todo" | remove calls for `agent:queued` only | the clear executor |
| "clear without --yes is refused" | exit 1, zero calls | the confirmation |
| "recover on a healthy store without --force is refused" | refusal | the guard |
| `check-cli-reference.sh` | pass | docs |

Mutation check: remove todo too → test 1 fails.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/build_queue/clear_test.exs
bash website/docs-app/scripts/check-cli-reference.sh
```

## Completion and handoff

- [ ] Verbs + runbook docs.
- Dependents: release notes for the first marker-writing release.

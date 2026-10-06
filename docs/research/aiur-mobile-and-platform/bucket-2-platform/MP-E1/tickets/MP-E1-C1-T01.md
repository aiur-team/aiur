---
ticket_id: MP-E1-C1-T01
feature_id: MP-E1
chunk_id: MP-E1-C1
bucket: 2-platform
title: Register the queue marker label and expose Issue.queued
status: blocked
blocked_by: [DESIGN-E1]
prior_units: [U5]
prior_boundaries: [BO #30, DSP #13]
prior_features: []
prior_findings: [MP-E1 F1, F5, F10]
size_owner: "GH_TRUST / GitHub access (github/issues.ex, 1248 lines; provisional, re-check per RC-23)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C1-T01 — Register the queue marker label and expose `Issue.queued`

> **Plan refresh (wave 0).** This ticket ships before the MP-R1..R7 refactor
> and cites paths at `45a290e3`. If U5 (GitHub outcomes) or MP-R1 has moved
> `github/labels.ex` or `github/issues.ex` by the time it starts, re-resolve the
> symbols below and re-check the size owner (RC-23). Per RC-19, U5 tickets must
> rebase over this change and keep the marker registration.

## Identity and outcome

- Bucket 2, feature MP-E1 (build queue), chunk C1 (core seams).
- **User value:** a waiting queue item can carry a visible GitHub label that is
  never mistaken for a lifecycle state, so `agent:queued` + `agent:todo` is one
  state, not a contradictory pair.
- **Deliverable:** `queued` (name per DESIGN-E1 OQ-4) is a registered marker
  suffix; `aiur init` and global-config startup seed it; `%Aiur.Issue{}` gains
  `queued: false` set at GitHub ingestion.
- **Non-goals:** no code writes the marker (that starts in C3-T04); no
  heal exemption (C1-T02); no queue module.

## Dependencies and blockers

- **Blocked by DESIGN-E1** (OQ-4: the label name and colour). If Kevin picks
  `agent:waiting`, substitute the suffix everywhere below.
- Predecessors: none. **Release-ordering constraint:** this ticket must ship
  in a release *before* any build that writes the marker (plan §8): a release
  without it parses `agent:queued` as a state label (`github/issues.ex:1176-1187`)
  and `DispatchAuthorization` denies the pair as contradictory
  (`github/dispatch_authorization.ex:51-53`).
- May run concurrently with C1-T03..T06 and all of C2.
- Contract: [queue-readiness-and-build-progress.md](../../../contracts/queue-readiness-and-build-progress.md) §1 rule 1, §7.

## Verified starting point (`45a290e3`)

- `src/lib/aiur/github/labels.ex:25` state suffixes; `:31-35` marker suffixes
  `watch paused parked rate-limit-fallback`; `:46-53` `label_set/2` seeds
  `marker_labels/1`; `:91-96` `marker_suffix?/1`; `:139-152`
  `state_description/1`.
- `src/lib/aiur/github/issues.ex:1176-1187` `state_label_suffix/2` drops any
  suffix for which `Labels.marker_suffix?/1` is true; `:1011-1012` sets
  `paused:`/`parked:` from `paused_label?/2`, `parked_label?/2` (`:1189-1203`).
- `src/lib/aiur/issue.ex:34-52` struct defaults (`paused: false`,
  `parked: false`, `labels: []`); `:100-107` `paused?/1`, `parked?/1`.
- `src/lib/aiur/global_config_startup.ex:81-86` ensures
  `state_labels ++ marker_labels ++ complexity_labels`.
- `github/issue_state.ex:289-310, 411-424` keeps marker labels through every
  state swap (F1).
- Tests: `src/test/aiur/github/labels_test.exs` (`describe "label_set/2"`).

## Chosen design

- Add `@queued_suffix "queued"` to `@marker_suffixes`. Every consumer of
  `marker_suffix?/1` then treats it as a marker: state parsing, swaps, and
  `label_set/2` seeding, with no other change.
- Add `queued_labels/1` (mirrors `parked_labels/1`) and
  `state_description("queued")` = "in the build queue; not yet ready" (copy per
  DESIGN-E1).
- `Issue` gains `queued: false` and `queued?/1`. GitHub ingestion sets it with
  a `queued_label?/2` helper beside `parked_label?/2`. Other trackers keep the
  default.
- Authority is unchanged: a human applying the marker counts as an allowed
  `<prefix>:*` applier (F1). The daemon never confers authority (plan §5.2).

## Implementation steps

1. `github/labels.ex`: add the suffix, `queued_labels/1`, the description.
2. `issue.ex`: field + `queued?/1` with a fallback clause like `parked?/1`.
3. `github/issues.ex`: `queued: queued_label?(label_names, prefix)` next to
   `:1012`; helper next to `:1197`. Keep the addition ≤ 15 lines (U8 debt).
4. Docs: `website/docs-app/concepts/ticket-lifecycle.md` marker table gets one
   row ("`agent:queued` — reserved for the build queue; not a state"). The
   full queue docs land with C6 and C9.

## Non-happy paths

- **Rollback** to a release without this change: the marker becomes a state
  label. Mitigated by the release-ordering constraint and C6-T03's
  `queue clear --remove-markers`.
- **Existing repositories** lack the label. Seeding covers `aiur init` and
  global-config startup; C3-T04 ensures it once before the first marker write
  (RQ-3). Whether `POST /issues/:n/labels` auto-creates a missing label is
  unverified (findings F11) and nothing depends on it.
- **Label prefix ≠ `agent`:** all helpers take `prefix`; tests cover `aiur`.

## Compatibility and rollout

No config change. One new label on `aiur init`. No migration. Rollback is safe
while no marker has been written.

## Verification

Tests (all in `src/test/aiur/github/`):

| Test | Expected | Fails without |
| --- | --- | --- |
| `labels_test.exs` "label_set/2 seeds the queued marker" | `"aiur:queued" in Labels.label_set("aiur", ["claude"])` and it is not in `state_labels/1` | the suffix in `@marker_suffixes` |
| `issues_test.exs` "queued marker is not a state label" | normalizing labels `["agent:todo", "agent:queued"]` gives `state_labels == ["todo"]`, `state == "todo"`, `queued == true` | the suffix (gives `["queued","todo"]`) |
| `issue_state_test.exs` "swap keeps the queued marker" | a swap `todo -> in-progress` on an issue carrying `agent:queued` issues no DELETE for `agent:queued` | the suffix |
| `dispatch_authorization_test.exs` "queued + todo is not contradictory" | `authorize/5` does not return the contradictory-labels denial | the suffix |

Mutation check: remove `@queued_suffix` from `@marker_suffixes`; each test
above must fail; restore; all pass. Run in a worktree (AGENTS.md).

Command (isolated HOME per memory note "mix test clobbers agent-token"):

```bash
env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/github/labels_test.exs test/aiur/github/issues_test.exs \
  test/aiur/github/issue_state_test.exs test/aiur/github/dispatch_authorization_test.exs
```

## Completion and handoff

- [ ] Marker registered, seeded, parsed as a marker; four tests pass and fail
      under the mutation.
- [ ] `concepts/ticket-lifecycle.md` row added.
- [ ] Shipped in a release before C3-T04 merges.
- Dependents: C1-T02, C3-T04, C9-T01.

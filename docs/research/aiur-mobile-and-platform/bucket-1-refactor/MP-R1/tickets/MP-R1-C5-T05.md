---
ticket_id: MP-R1-C5-T05
feature_id: MP-R1
chunk_id: MP-R1-C5
bucket: 1-refactor
title: Migrate alert emitters outside the orchestrator (39 files, 69 sites) from Aiur.Alerts to Aiur.Signal
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C5-T03]
prior_units: [U3]
prior_boundaries: ["#11 signal", "GHB #6", "GHC #5", "GHD #8", "ING #9", "EXE #26", "DEC #27", "CFG #2", "RUN #18", "WS #19", "CA #20", "TEL #29", "BUS #10"]
prior_features: [MP-R2]
prior_findings: []
size_owner: "per touched file: each change is a one-line call rename; no file grows"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C5-T05 — Alert emitters outside the orchestrator

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C5. Step S1, path-map row PR-07.
- **User value:** none visible (same alerts, same order). After this and C5-T06 no
  emitter depends on `Aiur.Alerts`; MP-E2 and MP-N4 can change routing in one place.
- **Deliverable:** replace `Aiur.Alerts.emit_system(topic, opts)` →
  `Aiur.Signal.alert(topic, opts)` and `Aiur.Alerts.emit_custom(topic, msg[, opts])` →
  `Aiur.Signal.agent_alert(topic, msg, opts)` (pass `[]` where the 2-arity form was
  used) in every file **outside** `src/lib/aiur/orchestrator/` and outside `alerts.ex`
  itself. Measured at base with
  `git grep -c 'Alerts\.emit_\(system\|custom\)' 45a290e3 -- src/lib`: 61 files, 160 sites
  in total; outside the orchestrator 39 files, 69 sites (GitHub/webhooks 11 files/18
  sites, executor/commands/alerts-family 11/30, other 17/21). Includes
  `workflow_store.ex:512` (the config→executor-attention edge C4-T04 left here) and the
  identity attention from C2-T01 if merged.
- **Non-goals:** orchestrator call sites (C5-T06); `Aiur.Alerts` internals; alert topics,
  messages, `needs_attention`, severities.

## Dependencies and blockers

- DESIGN-R1 §1; C5-T03.
- **Coordination with MP-R2-C2-T08** (`Aiur.Events` facade, batch migration by area):
  both edit emitter files. Rule: whichever batch is second rebases; neither changes the
  other's lines. MP-R2 chunks already make C2-T08 wait for this port.
- **Concurrent:** C5-T04, C5-T06 (disjoint directories).

## Verified starting point (`45a290e3`)

- Public alert API: `emit_system/2` (`alerts.ex:103-106`), `emit_custom/2,3`
  (`:108-119`, including `emit_custom(_,_,_) -> {:error, :invalid_alert}` for non-binary
  arguments). `Signal.agent_alert/3` must forward non-binary arguments unchanged so the
  sink keeps returning `{:error, :invalid_alert}`.
- Return values are used by some callers (`:ok | {:error, term()}`); the port returns the
  sink's value unchanged.

## Chosen design

Mechanical rename with `alias Aiur.Signal`; remove `alias Aiur.Alerts` where it becomes
unused (compile with `--warnings-as-errors`). One commit per component directory for
review. No semantic edits in the same PR.

## Implementation steps

1. `rg -l 'Alerts\.emit_(system|custom)' src/lib --glob '!src/lib/aiur/orchestrator/**' --glob '!src/lib/aiur/alerts.ex'`
   → the file list; record it in the PR body (expected 39 at base; the count at the
   implementation head is authoritative).
2. Rename per file; keep argument expressions byte-identical.
3. Tests that stub `Aiur.Alerts` via application env or Mox (if any, grep
   `rg -n 'Alerts' src/test/ | rg -i 'stub|mock|expect'`) are pointed at the sink config
   instead.
4. Prune stale allowlist keys (`* → Aiur.Alerts` for these components).

## Non-happy paths

- Missed call site → it still works (Alerts is unchanged); the checker keeps its allowlist
  key, so the miss is visible, not silent.
- A caller relied on `Aiur.Alerts` being loaded for a side effect at compile time: none
  found (Alerts has no `__using__`).

## Compatibility and rollout

No behaviour change. Rollback: revert.

## Verification

- Full suites of touched areas (CONTRIBUTING sibling-file rule): `test/aiur/github/`,
  `test/aiur/github_*_test.exs`, `test/aiur/webhooks/`, `test/aiur/events/`,
  `test/aiur/executor*`, `test/aiur/decision*`, `test/aiur/agent_runner/`,
  `test/aiur/workspace*`, plus `test/aiur/alerts_test.exs` and
  `test/aiur/agent_runner/turn_alerts_test.exs`.
- Equivalence (regression guard): for three representative emitters (one GitHub
  connectivity alert, one executor takeover alert, one agent-runner turn alert), assert
  the central `alerts.ndjson` line written after the change equals, field by field
  except timestamp, the line written by the same scenario on the pre-change commit
  (golden fixture captured in the PR).
- Source guard: `rg -n 'Alerts\.emit_' src/lib --glob '!src/lib/aiur/orchestrator/**' --glob '!src/lib/aiur/alerts.ex'`
  returns nothing.
- Command: `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" mise exec -- mix test test/aiur/alerts_test.exs test/aiur/agent_runner/turn_alerts_test.exs test/aiur/github test/aiur/webhooks test/aiur/events` and the other listed paths.
- Mutation check: n/a — a rename adds no behaviour; the golden equivalence tests are
  regression guards and are named so.
- Manual: foreground `scripts/aiurdev --test`, provoke one alert (pause an agent from
  the TUI), compare `aiur alerts` output with `main`.

## Completion and handoff

- [ ] Zero `Alerts.emit_*` outside orchestrator and alerts.ex; allowlist pruned.
- [ ] Docs: none.
- **Dependents:** C5-T06 completes the migration; MP-E2-C2 (escalation via the port).

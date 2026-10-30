# MIC-010 — Prove multi-instance control end to end on two live instances

**Kind:** capstone
**Provenance:** planned in plan v1
**Extends:** feeds #5954 (Railway guide multi-instance section)
**Complexity:** 2 — bounded operator acceptance run
**Risk:** medium
**Lane:** PC
**Phase hint:** 4
**Depends on:** MIC-002, MIC-004, MIC-006, MIC-007, MIC-008, MIC-009
**Requirements:** R1-R20 (acceptance owner)
**Researched at:** ab0c21424

Plan context: [plan](../../2026-10-23-001-feat-multi-instance-control-plan.md) (Definition of Done) · [pack index](../README.md)

## Outcome

Merged-base evidence that one operator machine controls two instances on different machines: status, fan-out reads, a remote setting, ownership rules, and one Executor loop.

## Scope

Run on current main, rebuilt on both machines, with a read token and a write token per instance:

1. `aiur --instance nuc status` and `aiur --instance all agents` (one instance stopped for one run: shown unreachable). A raw request with a write token and `max_scope: "read"` for `pause` gets 403 (server-side R4).
2. `aiur --instance nuc set agent.max_concurrent_builds 1`, `set --list`, `set --unset`; one audit line per write in the NUC's `control-audit.ndjson`.
3. A read token attempting `pause` gets 403 and an audit line. A write token attempting `operator_answer` gets 422 `denied_remote` (R20).
4. `instance.owns` on the NUC for one label: a ticket with that label runs on the NUC; stop the NUC; after heartbeat expiry the ticket runs on the PC with no label edit.
5. One Executor session runs `aiur --instance all executor-wait --as fleet-executor --json` and handles one wake from each instance; the NUC Executor is stopped for the run.
6. `aiur doctor` reports loopback-only distribution on both instances; on a container instance too when one exists (#5939/#5940 merged), else record "no container instance; not run".
7. Long-poll through `tailscale serve` holds for the chosen `--timeout` (record the value that works); repeat through the Railway edge when a Railway instance exists, else record "not run".

## Non-goals

Fixing deferred findings; new features found during the run go to the deferred ledger unless they block a criterion.

## Acceptance and verification

Record commands, outputs (tokens redacted), and the merged SHA in the PR body or a `docs/plans/2026-10-23-multi-instance-control/acceptance.md` file. Follow AGENTS.md "Manual testing" for anything that shows in the TUI.

## Docs to update

Add a "Control several instances from one machine" section to the Railway guide (#5954) or, if that guide has not merged, to `website/docs-app/guide/quick-start.md`'s two-instance section.

## Dependencies and conflicts

depends_on: MIC-002, MIC-004, MIC-006, MIC-007, MIC-008, MIC-009 (and through them #5945, #5947). Step 4 needs a lease store that both machines reach (#5947's recorded choice). Steps 6 and 7 use a container or Railway instance only when #5939/#5940 have merged; the stop condition stays two live instances.

## First slice Kevin can try

This ticket is the full slice.

# Validation report

- **Reviewed against:** `ab0c21424` (origin/main, 2026-10-23).
- **Pack state:** unpromoted. Membership and queue placement are proposed, not verified live.

## Mechanical checks

Run with a scratch checker over `graph.json`, the ticket documents, and the plan (the bundled `validate_build_order.py` applies to legacy packs only, so it was not used).

| Check | Result |
|---|---|
| Unique logical ids, every document exists, heading matches id | pass (10 tickets) |
| `Depends on` in each document equals `depends_on` in `graph.json` | pass |
| Complexity in each document equals `graph.json` | pass (26 points) |
| Every `depends_on` / `serializes_with` / `suggested_after` resolves to a MIC id or an existing issue | pass |
| Phases are computed levels and antichains (no internal `depends_on`) | pass: 4 phases, budget 5 |
| Same-phase `serializes_with` pairs | none |
| Every requirement R1-R20 owned by an executable ticket | pass (R20 added in round 2, owned by MIC-001) |
| Critical path | MIC-001 → MIC-002 → MIC-006 → MIC-010 (with #5945 parallel to MIC-001) |
| Per-lane earliest start | every lane starts in phase 1 |
| Dropped data-flow couplings each reconnected | pass: 4 entries in `integration_ledger` |
| Ticket ids carry no phase meaning | pass |
| No per-machine paths, hostnames, IPs, or secrets | pass (only documentation-range and loopback example addresses) |

## Semantic checks

1. Each ticket has one owner, one outcome, and a PR that can land green on its own. MIC-003 and MIC-007 have no hard dependency because they are built against contracts pinned in the plan (KTD1, KTD7, KTD8) and tested with fakes.
2. Edges pass the CI-green or contract-authority test: MIC-002 imports MIC-001 and #5945's plug; MIC-004 and MIC-006 extend `engine/remote.sh`; MIC-006 needs MIC-005's options; MIC-008 extends #5947's heartbeat and MIC-007's allowlist module.
3. One owner per contract: `aiur.control.call`/`result` (MIC-001), audit record (MIC-002), registry format (MIC-003), `config-overrides.json` and settable keys (MIC-007), heartbeat `owns`/`pool` fields (MIC-008 via amendment A3).
4. Feature acceptance has an owner (MIC-010) with named merged-base evidence.
5. Failure semantics are specified at each seam: unreachable instance shown, never dropped (MIC-004); unknown function or key refused with the build version (MIC-001, MIC-007); rejected override never stops boot (MIC-007); store outage fails closed with an attention (MIC-008); lost reply re-delivered (MIC-005).
6. In-flight snapshot taken on 2026-10-23 for #5938-#5954, #5611/PR 5903, #5685, #5803, #5887, #5897, #5902, #5911, #5695, #5698. Refresh before promotion.

## Adversarial review (one pass, security / feasibility / coherence lenses)

20+ citations spot-checked; all load-bearing ones matched. Findings and disposition:

| Severity | Finding | Disposition |
|---|---|---|
| P1 | KTD2 rejected the engine's own calls (tuple `env:` list, piped `PrMerge.Record.publish`, multi-statement handoff block, runtime-built expressions) | Fixed: 2-tuples allowed; `:deny` class; census lists runtime-built expressions by name (KTD2, KTD3, MIC-001) |
| P1 | Literal arguments still reach file paths and process names (`path:`, `root:`, `telemetry_file:`, `server:`) | Fixed: per-function option schema; `option_not_allowed`; hostile tests (KTD2, MIC-001) |
| P1 | Overrides layer placed in `settings_from` with a config-derived path would loop and would miss boot | Fixed: merge in `Reload.load_state`; env-only path under `~/.aiur/instances/$AIUR_INSTANCE_KEY/` (KTD8, MIC-007) |
| P1 | A new function name fails `existing_atoms_only` as `parse_error`, not `unknown_on_build` | Fixed: head-atom failure maps to `unknown_on_build` (KTD2, MIC-001 acceptance 6) |
| P2 | No body cap; auth after parse; `Module.concat` would mint atoms | Fixed: auth first, 64 KiB cap, segment match (KTD1, KTD2, MIC-002) |
| P2 | Killing a write call on timeout can leave a half-done write; abandoned waits pile up | Fixed: kill reads only (KTD4); one live wait per consumer (MIC-005) |
| P2 | Remote `executor-wait` sends caller pid/cwd that the daemon checks on its own host | Fixed: remote mode omits `env:` (MIC-006) |
| P2 | `aiurdev --instance` hits bare-run and rebuild classifiers | Fixed: strip before all classifiers (MIC-003) |
| P2 | MIC-009 checked variables, not bound sockets | Fixed: check bound addresses (MIC-009) |
| P2 | Store outage silently stops the pool; no-store installs not asserted unchanged | Fixed: attention + acceptance 7 (MIC-008) |
| P2 | MIC-007 asserted `settings!()` only; some keys may apply at restart | Fixed: per-key live/restart, behavioural assertion (MIC-007) |
| P2 | `validation-report.md` missing | Fixed: this file |
| P2 | A write token is near full control | Fixed: risk row and docs note (plan, MIC-002) |
| P3 | `:io.columns()` and local pre-call shell work differ remotely | Documented (KTD4, MIC-003) |
| P3 | MIC-002 failing-test description wrong (405, not issue lookup) | Fixed |
| P3 | Plan vs pack disagreed on `cli.md` handling | Fixed: hot-file exception everywhere |
| P3 | Timeout caps 900 s vs 600 s | Fixed: server 660 s, client 600 s |
| P3 | Actor in process dictionary is lost inside a Task | Fixed: passed as argument |
| P3 | Owner for `take`/`release` is the caller's `$USER` | Accepted; the audit's token name is the proof of caller |
| P3 | `ack_through` would duplicate `fast_forward_as`; stderr census unnecessary | Fixed: reuse `fast_forward_as`; census removed |
| P3 | Registry parser left open | Fixed: fixed-shape YAML read with `awk` |

No P0. All P1 findings are resolved in the documents. A second review pass is recommended after the operator reads the decisions, because the P1 fixes changed KTD2, KTD3 and KTD8.

## Second review pass (round 2, 2026-10-23)

`ce-doc-review` in headless mode with five lenses (coherence, feasibility, security, adversarial, scope guardian). The cross-model peer pass was not run (no sanctioned route in a non-interactive run). No P0. Round-1 fixes: option-key refusal and the overrides path hold; `unknown_on_build` and the overrides boot were incomplete and are fixed below. Graph re-checked after the edits: no cycles, `Depends on` lines equal `graph.json`, phases unchanged (MIC-004 gains MIC-001 and stays in phase 2).

| Severity | Finding | Disposition |
|---|---|---|
| P1 | A remote write token could call `operator_answer`, whose human-only checks run in bash | Fixed: new R20; human-guarded functions are `:deny`; census test (KTD3, MIC-001 AC7, MIC-002 AC5, MIC-010 step 3) |
| P1 | `--instance all` read-only guard was client-only; argv-decided commands (`alerts ack`) could fan out a write | Fixed: `max_scope` in KTD1, enforced by the server (R4, MIC-002 AC8, MIC-004) |
| P1 | R4/D7 refused every write under `all`, but F3/MIC-006 need `executor-wait` | Fixed: one named exception (R4, D7, MIC-004, MIC-006) |
| P1 | `unknown_on_build` covered only an unknown head atom; option keys and existing-atom function names fell through | Fixed: one rule for every unsafe-atom failure and every missing `{fun, arity}` on an allowlisted module (KTD2, MIC-001 AC6); clients never retry with fewer options |
| P1 | MIC-005 option keys never reached the MIC-001 allowlist | Fixed: "whichever merges second" in both tickets; ledger entry; MIC-006 AC8 |
| P1 | MIC-008 let an owner dispatch during a store outage (double dispatch) | Fixed: no new dispatch on store outage; partition test (KTD11, MIC-008 AC5) |
| P1 | MIC-008 needs an instance-level heartbeat that #5947 does not define | Fixed: amendment A3 adds it with a metadata map and a list-live-instances read |
| P1 | Fleet write tokens readable by agents on the Executor machine | Fixed: write tokens in `token_env`, `AIUR_TOKEN_*` scrubbed from agent environments, 0600 check (KTD7, MIC-003 AC5/AC8); residual risk DF-9 |
| P2 | Body cap "before parse" impossible: `Plug.Parsers` runs in the endpoint | Fixed: path-aware body reader, 413 (KTD1, MIC-002 AC9) |
| P2 | `existing_atoms_only` refuses alias segments that do not exist as atoms | Fixed: allowlist stores literal segment lists; real-path census test (KTD2, MIC-001 AC8) |
| P2 | `usage/1` takes a server name; `watch` default mode mutates a global baseline | Fixed: `usage/1` `:deny`; `watch` read only for `mode: :full`; positional atoms typed per entry |
| P2 | Option values typed but not constrained; caller-supplied `who:`/`env:` | Fixed: per-key constraints from the engine wrappers; identity keys and remote `env:` refused |
| P2 | Actor channel unspecified; `run/2` vs `run/3` | Fixed: `run/3` stores the actor in the task; `ControlCall.actor/0` (KTD4, MIC-001, MIC-002, MIC-007) |
| P2 | Crash and unlinked-task behaviour unspecified | Fixed: `Task.Supervisor.async_nolink`, crash → error marker, exit 1 (KTD4, MIC-001 AC9) |
| P2 | MIC-002 AC7 contradicted KTD4 for write timeouts | Fixed: split read/write; `timeout_unknown` audit outcome |
| P2 | Overrides: one bad entry discarded all; rollback dropped unknown keys silently; store-less load paths skipped the layer; `set` and boot used different validators; no instance key undefined | Fixed: per-entry validation, one `Overrides.apply/1` on every load path, `ReloadRejection.validate/1` everywhere, refuse `set` without a key (KTD8, MIC-007) |
| P2 | MIC-005 supersede changed default waits; inbox has no consumer-keyed waiters; `ack_through` not idempotent after a trim; journal reset wedges the fleet wait | Fixed: supersede only `defer_ack` waits, consumer-keyed waiters, cursor no-op first, `journal_reset`, client cursor keyed by `instance_id` (KTD10, MIC-005, MIC-006) |
| P2 | A paused owner holds its owned tickets | Fixed: `dispatching` flag (KTD11, MIC-008 AC8) |
| P2 | A1 did not narrow #5945 AC4 or say read tokens pass the plug on the control POST; A6 listed 5 of 11 tickets and no map; A3 fixed the store as Postgres | Fixed in README amendments |
| P2 | MIC-009 could break container boot if it merges before #5939/#5940; MIC-010 needed Railway | Fixed: `suggested_after`; Railway and container steps conditional |
| P2 | MIC-004 test reads MIC-001's allowlist without an edge | Fixed: edge MIC-001 → MIC-004 plus a checked-in fixture |
| P2 | Client timeouts had no owner | Fixed: MIC-003 and MIC-006 scope |
| P2 | Plain HTTP to tailnet hosts sends the token on a name check | Fixed: HTTPS for every non-loopback host (R10, MIC-003 AC5) |
| P3 | KTD1 reason list incomplete; unused `command`; KTD2 citations (`root:`, `telemetry_file:`); R5/R19 shorter than tickets; acceptance numbering | Fixed |
| P3 | No idempotency key on writes | Deferred: DF-8; v1 clients never retry writes |
| P3 | KTD9 key list wider than the operator's examples | Kept: each key is one allowlist line, and the list matches the operator's examples of caps, routing and priority |

## Artifact hashes (SHA-256, first 16 hex)

Recorded at commit time in the PR description; recompute with `sha256sum docs/plans/2026-10-23-*multi-instance-control*` and the files in this folder.

## Accepted exceptions

- `website/docs-app/reference/cli.md` is edited by seven tickets; treated as a hot file, not an edge.
- External prerequisites #5945 and #5947 are leveled as phase-1 peers; #5945 assumes amendment A1.

# MP-R7 C4 status

Historical disposition updated 2026-11-21 UTC by MP-R7-C4-T03 (#3478).
This bounded record replaces no historical chunks outside C4.

## MP-R7-C4 — Physical package: blocked (no-go)

The [promotion scorecard](plan.md) recheck still fails criterion 1 and does not establish criterion 5. The prescribed no-start tests now pass; the physical package remains parked.
Keep harness-adapters as a logical in-app component. A merged promotion
record is evidence of the decision, not permission to start the moves.

| Ticket | Disposition |
| --- | --- |
| C4-T01 (#3476) | Merged: component-declared supervision children (#5200) |
| C4-T02 (#3477) | No-go record; this change |
| C4-T03 (#3478) | Re-scoped in-tree repair; no-go for physical package move. Current boundary census: 55 live keys (26 out, 29 in), down from 94 at #3477; the harness-adapters allowlist has 26 entries. Provider-family usage, setup-I/O, invocation context, event-humanizer behavior/helpers, shared token normalization, pricing-window routing dependencies, provider/account-generation facade calls, and native-capture calls now use harness/kernel contracts or app-level composition; the config-owned dotenv parser replaces the setup-wizard wrapper. The no-start harness subset passes (1,529 tests, 0 failures, 3 excluded). The ≤40 total live-key target remains unmet; the full-suite run timed out after 2,530 tests. See [recheck](plan.md#c4-t03-in-tree-recheck-2026-11-21). |
| C4-T04 (#3479) | Blocked: adapter moves |
| C4-T05 (#3480) | Blocked: physical package release/boot check |

Re-check when a second consumer or independent-release need is recorded,
or MP-R1-C11 requests a plan refresh. Then rerun all five criteria,
including two consecutive post-rule releases with zero allowlisted
violations in both directions and an independent test run. Manual
foreground acceptance remains an Executor post-deploy check.

# Analytics + Streamdeck — planning pack index

Generated view over `build-order.json` (canonical) — do not treat copied
status as live. GitHub owns ticket facts; Aiur owns runtime facts.

- Canonical graph: `build-order.json` (validated: 0 errors, 0 warnings)
- Research: `../..//research/` — `streamdeck-architecture.md`,
  `analytics-tickets.md`, `security-trust-boundary.md` (copies with hashes in
  `evidence/`)
- Executor handoff: `../../executor/analytics-streamdeck-handoff.md`
- Ticket documents: `tickets/` (each links its GitHub contract)

## Logical → GitHub mapping (pre-existing issues; created 2026-07-29/30)

| Logical | GH | Title |
|---|---|---|
| AS-101 | #991 | Bound RunTelemetry.Writer mailbox |
| AS-102 | #1338 | Record run telemetry by default |
| AS-103 | #1339 | Bound telemetry stream growth |
| AS-104 | #1340 | Complexity breakdown chart |
| AS-105 | #1341 | Brush-to-zoom shared time domain |
| AS-201 | #1342 | Spike: SD+ direct-HID go/no-go |
| AS-202 | #1343 | Scaffold packages/streamdeck |
| AS-203 | #1344 | HTTP pause/resume endpoints |
| AS-204 | #1345 | Grid projection endpoint |
| AS-205 | #1346 | Phoenix Channel for fleet state |
| AS-206 | #1347 | Per-agent classified event feed |
| AS-207 | #1348 | Mode state machine |
| AS-208 | #1349 | Dial semantics + paging math |
| AS-209 | #1350 | Key content model |
| AS-210 | #1351 | Event flattening + scroll window |
| AS-211 | #1352 | /streamdeck LiveView emulator |
| AS-212 | #1353 | Emulator interaction hooks |
| AS-213 | #1354 | Device transport + lifecycle |
| AS-214 | #1355 | Key rendering pipeline |
| AS-215 | #1356 | Touch strip rendering |
| AS-216 | #1357 | Packaging: udev/systemd/docs |
| AS-217 | #1358 | End-to-end proof (capstone) |
| AS-301 | #1359 | Dispatch allowlist + provenance |
| AS-302 | #1360 | Fail-closed digest trust |
| AS-303 | #1361 | CODEOWNERS degradation alerts |
| AS-304 | #1362 | Human-only merge gate |

These issues predate the pack (created directly under operator authority);
the marker-based publisher was not used. The GitHub bodies are the
worker-ready contracts; `tickets/` records the graph metadata.

## Wave profile (derived, diagnostic)

- **W1 (9 wide):** AS-101 AS-201 AS-202 AS-203 AS-204 AS-205 AS-206 AS-301 AS-302
- **W2 (7):** AS-102 AS-103 AS-207 AS-209 AS-213 AS-303 AS-304
- **W3 (7):** AS-104 AS-105 AS-208 AS-210 AS-211 AS-214 AS-216
- **W4 (2):** AS-212 AS-215
- **W5 (1):** AS-217 capstone

Critical path: AS-204 → AS-209 → AS-211 → AS-212 → AS-217 (and
AS-201 → AS-213 → AS-215 → AS-217). First-slot spine: AS-201 (gates the
device layer), AS-202 (gates all core logic), AS-204, AS-101.

Cliques: dashboard-ui (AS-105 ⇄ AS-211 ⇄ AS-212, `serializes_with`);
AS-202 alone owns root/CI files and lands before other streamdeck work.

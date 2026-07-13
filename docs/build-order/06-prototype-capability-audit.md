# Prototype Capability Audit

**Production baseline:** `origin/main` at
`16d6033d8824c8cb53ac09e2129f69af751be8c4`

**Prototype evidence:** the versioned files and hashes in
[design-manifest.md](design-manifest.md)

**Audit purpose:** identify every production capability hidden behind the
refreshed prototype before issue publication. This is a boundary audit, not a
pixel-perfect implementation prescription.

## Result

The refreshed dashboard delta is not one frontend ticket. It contains five
independent systems: shared navigation, an all-state Units projection, applied
runtime controls, Decision/Commands provenance, and durable provider-neutral
usage/accounting. The recommended companion pack therefore contains fifteen
issues. Those issues remain outside the Build Order root and completion math.

The Build Order graph itself also needs four boundaries that the earlier
eleven-ticket draft compressed: trustworthy repository-qualified event
identity, a real browser/accessibility/performance harness, vendored layout
assets separated from DOM/SVG integration, and interaction separated from
responsive scale proof. The bounded Build Order recommendation is therefore
fifteen implementation/capstone issues.

## Current production facts

At the audited commit:

- `/`, `/decisions`, and `/decisions/:id` are LiveView routes; `/analytics` is
  an authenticated controller-backed report rather than a placeholder tab.
- Units is already one Fleet table. It combines running, retrying, and idle
  rows and offers basic running/blocked/paused/stuck/finished filters.
- `DashboardLive` receives provider changes through PubSub and coalesces
  reloads; a new page does not need browser polling to become live.
- `ControlCenterCache`, the presenter, durable Decision history, revisions,
  delivery, latency, and supervisor answers already exist.
- the current agent-log dialog is running-agent oriented. Sending and pausing
  exist, but an all-state ticket context and applied resume lifecycle do not.
- `AgentChat.pause/1`, `AgentChat.resume/1`, `AgentChat.capabilities/1`, and
  `Slots.set_max_concurrent_agents/1` exist. The capacity setter requires a
  positive integer; the prototype's zero value is not a valid production
  contract.
- current token totals are transient and current-run oriented. Completed
  ticket attribution, durable per-model history, versioned estimates, and a
  complete Remote Control path do not exist.
- Codex exposes structured rate-limit snapshots. Claude does not yet have a
  complete Aiur account-meter contract, and `claude-repl` has no current
  structured token/cost ingestion path.
- direct Decision lookup exists through `DecisionStore.get/2`; the overview is
  intentionally bounded. Supervisor confidence is persisted, but the current
  presentation omits it. Exact backend/model provenance is not canonical.

PR #971 remains useful planning evidence, not an implementation base. OCC
capstone #1026 is complete. Active #1033 and #1034 own current-dashboard
documentation and the Operator-to-Executor vocabulary transition respectively;
new shell work sequences after #1034 and owns its own future documentation.

## Visible feature to production contract

| Prototype capability | Reusable production capability | Missing contract or backend work | Planned owner |
|---|---|---|---|
| Responsive Units/Commands/Build Order/Analytics navigation | Real routes, authentication, theme and Analytics report | Shared route metadata, desktop/sidebar and mobile/bottom navigation, safe-area/reflow behavior | DASH-001 |
| Live/Unfinished/All/None plus overlapping state chips | One Fleet table with basic filter params | Current-run unit universe, terminal retention, canonical predicates, exact truth table, URL/count semantics | DASH-002, DASH-003 |
| Finished/queued/non-running Units | Current running/retrying/idle snapshots | Recoverable same-run membership journal, terminal retention, and honest missing/stale activity | DASH-002 |
| Backend, exact model, effort, complexity, lane and progress | StatusReport owns lifecycle/backend facts; AgentList owns event progress | Common typed identity, preserved StatusReport ownership, extracted event activity, and joined Units projection | BO-004, BO-005, DASH-002 |
| Rich row/ticket dialog | Running-only agent-log dialog | All-state on-demand cached ticket context, safe dependency and cross-surface navigation, no Build Order mutation handlers | BO-003, BO-011, adopted by DASH-003 |
| Per-unit pause/resume toggle | Pause/resume request functions and capability checks | Correlated request, accepted, worker-applied/rejected/expired acknowledgement and conflict recovery | DASH-004, DASH-005 |
| Max-agents stepper | Positive-integer runtime capacity setter | Authenticated UI reconciliation and stale/error handling; zero remains invalid | DASH-005 |
| Commands cards and filters | Durable Decision state machine, direct lookup, revisions and delivery | Provenance schema, complete lookup/search semantics and presentation catch-up without lifecycle loss | DASH-006, DASH-007 |
| Per-ticket/model/backend tokens | Transient Codex/Claude token folds | Raw provider-neutral measurements plus durable single-writer delta checkpoints and attributed ledger | DASH-008, DASH-009 |
| Claude Remote Control tokens/cost | Remote Control turn/session identity only | Authenticated, bounded structured request ingest and correlation behind a human-owned protocol gate; required coverage, not an unsupported terminal state | DASH-010 |
| Dollar values by ticket/model/build | Some provider cost and token counters | Versioned API-equivalent pricing, exact basis buckets, coverage and selected-member grouping | DASH-011 |
| Codex session/weekly meter and plan | Structured Codex account/rate-limit protocol | Account-generation-aware LKG projection and product-plan semantics | DASH-012 |
| Claude session/weekly/API plan meter | No complete stable Aiur projection | Structured Claude subscription and API-key adapter; no interactive-output scraping | DASH-013 |
| Live units, remaining, progress, elapsed and ETA | Individual row/run counters | Canonical current-run denominator, weighting, wall-clock start and evidence-based ETA | DASH-014 |
| Provider/Aiur summary cards and drill-down | No shared durable summary | Authenticated, accessible, live-updating composition with explicit scope/basis/freshness | DASH-015 |
| Build Order selector and graph | GitHub issue/dependency clients and dashboard LiveView patterns | Root catalog, complete paginated graph, LKG health, pure join and URL-backed route | BO-001..BO-012 |
| Graph geometry and routed edges | Static-asset and LiveView hook seams | Pinned local worker engine, measured DOM/SVG adapter and deterministic readable fallback | BO-008..BO-010 |
| Chain selection, dialog navigation, pan/zoom | Prototype hover and scroll only | Keyboard/touch/focus semantics, explicit controls, reduced motion and persistent selected context | BO-011..BO-013 |
| 20/50/100-node usability | Illustrative fixed 31-node data only | Synthetic degradation/cycle/scale fixtures plus current-root dogfood | BO-008, BO-014, BO-015 |

## Prototype interaction audit

The committed HTML was exercised in a real browser at desktop and 390 by 844
mobile viewports, in both themes, rather than inspected only as source.

- The graph renders four lanes, six phases, 31 nodes, 14 visually cleared
  edges and 10 visually blocking edges.
- The graph viewport scrolls vertically (`758px` client height versus `1832px`
  content height). The HTML exposes no functioning zoom controls, confirming
  the written-constraint drift recorded in the design manifest.
- A node opens a dialog with Ticket description, Dependencies, Progress, and
  Logs sections plus chat/GitHub actions.
- Commands renders cards and Open, Blocking, Resolved, and All filters; the
  mock does not prove the complete durable Decision lifecycle.
- At the mobile viewport the fixed navigation occupies the bottom edge, and
  the measured pause targets are about `34px` square. Production acceptance
  therefore requires content safe-area padding and at least `44px` named touch
  controls rather than copying those measurements.

The HTML also contains illustrative or dead client-only paths. No ticket may
treat the mock dataset, fixed coordinates, missing controls, hard-coded links,
or browser-local mutations as a source of truth.

## Boundary decisions from the audit

1. Build Order remains read-only for GitHub planning and Aiur runtime
   mutations. Shared context may link to existing chat, Commands, and control
   surfaces without deleting or duplicating those independently governed paths.
2. GitHub is live truth for order identity, current membership, ticket facts,
   lifecycle and hard blockers. Aiur is live truth for current activity and
   retained usage. The planning JSON is an approved baseline, not the live
   database after publication.
3. Cards receive bounded summaries only. Full body/log/context data is loaded
   from cached normalized providers after selection; no node triggers GitHub
   I/O or parses a workspace log.
4. A bad selected graph must not hide other roots. Catalog health and selected
   graph health remain separate. Structural invalidity, stale last-known-good,
   unavailable, member warnings and cycles are distinct states.
5. The edge/readiness vocabulary is `cleared`, `blocking`,
   `terminal_unsatisfied`, `unknown`, and `cyclic`. Conservative readiness
   precedence is cyclic, unknown, terminal-unsatisfied, blocking, then ready.
6. The usage ledger uses the repository's proven file-first pattern: a single
   supervised writer, append-only versioned NDJSON authority, and crash-safe
   atomic checkpoint/aggregate projections. A new application database is not
   introduced for this bounded local-first feature. The behavior boundary
   leaves a future Postgres/multi-controller adapter possible.
7. Usage and account-meter facts never leak through the dashboard's optional
   unauthenticated local mode. Without authenticated Executor mode, tokens,
   costs, plan/auth mode, quota/rate/credit windows, percentages, resets, and
   drill-down APIs render a locked state and are absent from assigns/events.

## Adjacent existing work

- #132 overlaps durable per-ticket token/cost storage. DASH-009 supersedes its
  storage/accounting contract; #132's proposed opencode side-panel surface is
  not silently pulled into this dashboard scope.
- #845 is a broader optimization program that recommends Postgres and
  multi-controller analytics. The local file-first decision is intentional for
  this bounded feature; cross-run BI and a database migration remain a later
  authorized program behind a storage behavior.
- #930 is debug-only telemetry and may provide evidence or vocabulary, but it
  is not the canonical normal-run usage source.
- #1067 tracks separately human-blocked Linear parity and cannot change this
  GitHub-only feature's count or ETA.

## Publication implication

Publish one Build Order root with fifteen direct member issues, fifteen
standalone dashboard companions, and one human-blocked skill-delivery issue.
Companion dependencies are real native blockers even though companions are not
root members. Every companion is held by the predecessor-baseline gate, and
named sibling-protocol gates remain non-dispatchable until a human records
their resolution. No issue receives an `agent:*` label during planning.

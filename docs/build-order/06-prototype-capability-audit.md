# Prototype Capability Audit

**Production baseline:** `origin/main` at
`9849f32963c2a65367bce565b3f5ede3777c218f`

**Prototype evidence:** the versioned files and hashes in
[design-manifest.md](design-manifest.md)

**Audit purpose:** identify every production capability hidden behind the
refreshed prototype before issue publication. This is a boundary audit, not a
pixel-perfect implementation prescription.

## Result

The refreshed dashboard delta is not one frontend ticket. It contains five
independent systems: shared navigation, an all-state Units projection, applied
runtime controls, Decision/Commands provenance, and durable provider-neutral
usage/accounting. Worker-boundary review further separates recovery from Units
policy, Decision query from provenance migration, account identity from usage,
meter contracts from adapters, local telemetry transport from normalization,
financial authorization from presentation, run status from provider UI,
append/checkpoint storage from aggregate query and compaction, and selected
Build Order accounting from generic grouping. The recommended companion pack
therefore contains twenty-five issues. Those
issues remain outside the Build Order root and completion math.

The Build Order graph itself also needs boundaries that the earlier draft
compressed: configured-repository Issue/StatusReport identity separated from
event propagation, detail and bounded activity history separated from the
accessible base context and Build Order adapter, a real
browser/accessibility/performance harness, vendored layout assets separated
from DOM/SVG integration, and interaction separated from responsive scale
proof. The bounded Build Order recommendation is therefore nineteen
implementation/capstone issues.

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
- the documentation closeout includes a Playwright command that starts a
  synthetic Phoenix/LiveView fixture, captures desktop/mobile themes, and
  rejects horizontal overflow. It does not yet supply the shared authenticated
  interaction, automated-accessibility, trace, or performance harness.
- direct Decision lookup exists through `DecisionStore.get/2`; the overview is
  intentionally bounded. Supervisor confidence is persisted, but the current
  presentation omits it. Exact backend/model provenance is not canonical.
- #1076 pins warmed-slot OpenCode provider configuration against parent
  overrides. It does not expose provider-account meters or durable attributed
  usage and therefore does not close any DASH-008..015 or DASH-018..021 gap.

PR #971 remains useful planning evidence, not an implementation base. OCC
capstone #1026, terminology ticket #1034, documentation ticket #1033, and
closeout PR #1073 are complete on `main`. The configured `v2` integration
target still lacks that baseline, so new shell work remains gated on an
explicit resolved branch/SHA and owns its own future documentation.

## Visible feature to production contract

| Prototype capability | Reusable production capability | Missing contract or backend work | Planned owner |
|---|---|---|---|
| Responsive Units/Commands/Build Order/Analytics navigation | Real routes, authentication, theme and Analytics report | Shared route metadata, desktop/sidebar and mobile/bottom navigation, safe-area/reflow behavior | DASH-001 |
| Live/Unfinished/All/None plus overlapping state chips | One Fleet table with basic filter params | Recoverable current-run unit universe, terminal retention, canonical predicates, exact truth table, URL/count semantics | DASH-002, DASH-016, DASH-003 |
| Finished/queued/non-running Units | Current running/retrying/idle snapshots | Recoverable same-run membership journal, terminal retention, and honest missing/stale activity | DASH-002 |
| Backend, exact model, effort, complexity, lane and progress | StatusReport owns lifecycle/backend facts; AgentList owns event progress | Configured-repository Issue/StatusReport identity, typed observation propagation, extracted event activity, and joined Units projection | BO-004, BO-017, BO-005, DASH-016 |
| Rich row/ticket dialog | Running-only agent-log dialog | Root-independent cached detail, bounded sanitized activity history, accessible base context, and a narrower Build Order relationship adapter with truthful destinations | BO-016, BO-019, BO-018, BO-011, adopted by DASH-003 |
| Per-unit pause/resume toggle | Pause/resume request functions and capability checks | Correlated request, accepted, worker-applied/rejected/expired acknowledgement and conflict recovery | DASH-004, DASH-005 |
| Max-agents stepper | Positive-integer runtime capacity setter | Authenticated UI reconciliation and stale/error handling; zero remains invalid | DASH-005 |
| Commands cards and filters | Durable Decision state machine, direct lookup, revisions and delivery | Complete retained lookup/query, trusted provenance/confidence migration, and presentation catch-up without lifecycle loss | DASH-006, DASH-017, DASH-007 |
| Per-ticket/model/backend tokens | Transient Codex/Claude token folds | Shared opaque account generation, raw provider-neutral measurements, durable single-writer delta checkpoints/ledger, crash-safe aggregates, and dimension-preserving retention | DASH-018, DASH-008, DASH-009, DASH-024, DASH-025 |
| Claude Remote Control tokens/cost | Remote Control turn/session identity only | Authenticated bounded local telemetry/correlation plus request normalization behind a human-owned protocol gate; required coverage, not an unsupported terminal state | DASH-019, DASH-010 |
| Dollar values by ticket/model/build | Some provider cost and token counters | Versioned API-equivalent pricing, exact basis buckets, coverage and current selected-member integration | DASH-011, DASH-023 |
| Codex session/weekly meter and plan | Structured Codex account/rate-limit protocol | Shared account generation, provider-meter LKG contract, and structured Codex adapter/availability compatibility | DASH-018, DASH-012, DASH-020 |
| Claude session/weekly/API plan meter | No complete stable Aiur projection | Structured Claude subscription and API-key adapter; no interactive-output scraping | DASH-013 |
| Live units, remaining, progress, elapsed and ETA | Individual row/run counters | Canonical current-run denominator, weighting, wall-clock start, evidence-based ETA, and independently shippable accessible UI | DASH-014, DASH-022 |
| Provider/Aiur usage cards and drill-down | No shared durable summary | Enforced financial-data boundary plus authenticated, accessible, live-updating run/build composition with explicit scope/basis/freshness | DASH-021, DASH-015, DASH-023 |
| Build Order selector and graph | GitHub issue/dependency clients and dashboard LiveView patterns | Bounded root catalog, complete paginated graph, LKG health, typed event join, root-independent detail/history/context, and URL-backed route | BO-001..BO-012, BO-016..BO-019 |
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
6. Usage storage uses the repository's proven file-first pattern: a single
   supervised append/checkpoint writer, a separate crash-safe aggregate/query
   projection, and a separately proven retention/compaction lifecycle. A new
   application database is not introduced for this bounded local-first
   feature. The behavior boundaries leave a future Postgres/multi-controller
   adapter possible.
7. DASH-021 ensures usage and account-meter facts never leak through the dashboard's optional
   unauthenticated local mode. Without authenticated Executor mode, tokens,
   costs, plan/auth mode, quota/rate/credit windows, percentages, resets, and
   drill-down APIs render a locked state and are absent from assigns/events.

## Adjacent existing work

- #132 overlaps durable per-ticket token/cost storage.
  DASH-009/DASH-024/DASH-025 supersede its
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

Publish one Build Order root with nineteen direct member issues, twenty-five
standalone dashboard companions, and one human-blocked skill-delivery issue.
Companion dependencies are real native blockers even though companions are not
root members. Every companion is held by the predecessor-baseline gate, and
named sibling-protocol gates remain non-dispatchable until a human records
their resolution. No issue receives an `agent:*` label during planning.

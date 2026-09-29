# Duplication concept closure ledger

Frozen source: `3339b887196d5e9aefb273117a14bf33391ee41f`.
This ledger assigns each of the 275 inherited `category: duplication` IDs in
the 29 raw review units to one primary concept family. It preserves every raw
ID, source location, and severity. A family is a review lens, not an additional
defect or an additive LOC saving. The existing
`duplication-concept-inventory.json` is the exhaustive ID roster; the table
below is its classification key. Any ID absent from an exception cell takes
that unit's default family. Empty raw units have no IDs to assign.

## Classification key

| Raw unit | Default family | Exceptions (`family: ID suffixes`) |
|---|---|---|
| agent-backends-cc | provider | state: 38; shell: 32; workspace: 33; usage: 13,14; orchestration: 11 |
| agent-backends-oc | provider | orchestration: 16; workspace: 33; primitive: 31 |
| agent-runtime | provider | events: 22; state: 23; primitive: 32; workspace: 40 |
| build-order | build | usage: 20; primitive: 35; identity: 17,18 |
| dup-by-body | primitive | See the complete suffix map below |
| events-webhooks-executor | events | primitive: 08; github: 17; durable: 32 |
| github-a | github | workspace: 05; identity: 08; primitive: 25 |
| github-b | github | state: 12,13; identity: 30; durable: 35; primitive: 32 |
| loose-1 | primitive | decision: 08,33; events: 09,13; scheduler: 18; github: 20; shell: 34 |
| loose-2 | primitive | state: 14; shell: 16; usage: 23,39; provider: 28,29; build: 37; web: 15,33; decision: 11,12 |
| loose-3 | primitive | workspace: 06; durable: 11,24,29,31,39; identity: 15; scheduler: 18; provider: 28; build: 30,34; events: 38,42; decision: 40 |
| loose-4 | primitive | build: 12,19; durable: 13,14; usage: 26 |
| nonelixir-shell | shell | usage: 10,11; workspace: 16; identity: 23; provider: 28 |
| orch-a | orchestration | state: 13,28; events: 14; durable: 16; identity: 30 |
| orch-b | orchestration | state: 04,21,29; github: 06,24; identity: 28 |
| platform-misc | platform | state: 10,21,22; durable: 14; primitive: 15,33; workspace: 16,17; github: 24; build: 28; decision: 30; provider: 36; identity: 20 |
| telemetry-usage | usage | durable: 22; primitive: 34 |
| tests-1c, tests-2, tests-3, tests-5, tests-6 | tests | None |
| web-occ | web | state: 02; decision: 04,21; build: 19,30; usage: 20; primitive: 18 |
| web-rest | web | usage: 03,10; orchestration: 07,15; workspace: 09; identity: 17; durable: 20; provider: 21; primitive: 33 |

`dup-by-body` suffix map (all 60, exactly once):

| Family | Suffixes |
|---|---|
| usage | 01,06,24,28,40,47,57 |
| decision | 02,03,25,37 |
| durable | 04,20,31 |
| orchestration | 05,08 |
| build | 09,11,17,18,29,38,44,51,56 |
| web | 10,12,15,21,22,48,54,55 |
| workspace | 13,14,23,59,60 |
| platform | 16 |
| events | 19,46 |
| github | 26,32,36,41,42,45,49,50,52 |
| identity | 27,30 |
| provider | 07,33 |
| shell | 34 |
| primitive | 35,39,43,53 |
| scheduler | 58 |

## Cross-boundary contract families

These are source-role reconciliations. Each inherited ID below remains the
finding that states its own claim; the family does not independently verify
every count quoted there.

- **State:** `agent-runtime-23`, `github-b-12`, `orch-a-13`,
  `platform-misc-10`, `web-occ-02`, `dup-by-body-45` touch related state and
  label words. `src/lib/aiur/github/labels.ex:25-35` explicitly separates
  lifecycle suffixes from marker suffixes. `dup-by-concept-01` is the focused
  draft; it overlaps `agent-runtime-23` and `agent-backends-cc-38`.
  Tracker disposition, marker labels, write permission, pause reason, and
  rendered row status need separate typed roles.
- **Events:** `agent-runtime-22`, `events-webhooks-executor-07`,
  `loose-3-38`, `orch-a-14`, `dup-by-body-46` span topic production and
  consumption. `src/lib/aiur/events/github_firehose.ex:420-429` builds PR
  topics after source-specific merge admission; the strict parsers at
  `src/lib/aiur/orchestrator/event_topics.ex:83-105` consume suffixes.
  `dup-by-concept-02` and `dup-by-name-03` overlap this family. A shared
  grammar should not absorb webhook admission, replay, or subscription policy.
- **GitHub:** `github-a-16`, `github-a-17`, `github-b-05`,
  `events-webhooks-executor-17`, `orch-b-24`, `dup-by-body-42` connect
  pagination, headers, request attribution, conditional lists, and review
  polling. Transport helpers can own mechanics, while request direction,
  consumer, rate pool, cache identity, and `304` meaning remain explicit.
- **Build:** `build-order-05`, `build-order-12`, `loose-4-19`,
  `web-occ-19`, `dup-by-body-09` relate graph metric derivation, source
  overlays, metadata and route adapters. `src/lib/aiur/build_order/metadata.ex:21-55`
  parses bounded complexity, phase and lane labels with diagnostics; a
  generic label split would lose this contract. Source paging and provenance
  stay with the respective source adapters.
- **Provider:** `agent-backends-cc-04`, `agent-backends-oc-33`,
  `agent-runtime-40`, `platform-misc-36`, `dup-by-body-33` concern session,
  process, and credential mechanics. Backend binding failures, `auth_mode`
  representation, remote PID handling, and provider credential precedence
  differ. Share typed process metadata or transport mechanics only after
  these policies are made explicit.
- **Orchestration and scheduler:** `orch-a-02`, `orch-b-10`,
  `web-rest-15`, `loose-1-18`, `loose-3-18`, `dup-by-body-58` repeat control
  calls, transition/admission checks and keyed queue mechanics. Lifecycle
  fences, worker-host selection, lane identity, cancellation and persistence
  semantics are owner-specific. Same function name is not a safe extraction
  criterion.
- **Decision:** `loose-1-08`, `loose-3-40`, `platform-misc-30`,
  `web-occ-04`, `dup-by-body-02` share request validation and lifecycle
  vocabulary across storage, API and UI. Canonical state/kind parsing can
  have one owner; response envelopes and action availability remain separate.
- **Durable:** `events-webhooks-executor-32`, `loose-3-24`,
  `loose-4-13`, `telemetry-usage-22`, `dup-by-body-31` repeat path derivation,
  bounded reads, checksums, and atomic-write mechanics. Retention, symlink
  handling, `fsync`, quarantine, and degraded-state reporting differ by store.
- **Usage:** `telemetry-usage-07`, `nonelixir-shell-11`, `web-rest-10`,
  `build-order-20`, `dup-by-body-06` connect collection, reduction, scope,
  storage and presentation. Preserve unknown values, precision, time window,
  and provider-specific fields rather than flattening them to one default.
- **Identity:** `github-a-08`, `orch-b-28`, `platform-misc-20`,
  `web-rest-17`, `dup-by-body-27` concern case, nil, false, repo, ticket,
  and dual-key semantics. Normalize at a typed boundary only where those
  rules match; a generic map accessor can hide the distinction.
- **Workspace and platform:** `platform-misc-16`, `loose-3-06`,
  `nonelixir-shell-16`, `dup-by-body-13`, `dup-by-body-60` repeat path and
  process work across local, remote, agent, and launcher contexts. Path
  containment, host identity, failed liveness probes and cleanup guarantees
  have different contracts. `platform-misc-20` also belongs to environment
  grammar, but its primary assignment above is identity because it concerns
  resolving variable references.
- **Shell, web, tests, primitives:** `nonelixir-shell-04`,
  `loose-2-16`, `web-occ-16`, `web-rest-18`, `tests-6-13`,
  `loose-1-17` are maintenance clusters. Command tables, view formatting,
  test polling, and tiny helpers can gain a single owner where behavior
  matches. These broad groups are not new production-risk findings.

## Verification and limits

The classification key covers the 275 unique IDs from 29 raw units: each
nonempty unit has one default family, each listed exception exists in its
unit, and the 60 `dup-by-body` suffixes are assigned exactly once. The
specific cross-boundary examples above were checked against the frozen source
at the stated anchors; all other source locations and severity claims remain
in their raw findings. This ledger is a bounded reconciliation of inherited
duplication findings, not a semantic rereview of every inherited assertion or
an exhaustive search for unnamed concepts. It makes no LOC or savings claim.

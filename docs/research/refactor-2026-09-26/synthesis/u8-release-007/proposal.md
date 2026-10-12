# U8 release-head worker assignment proposal

Planning-only proposal for `main@465aca643527ea94a4d0d6d7c178c5d23d2aaf57` (`v0.0.7`). The exact assignment is [assignments.csv](assignments.csv): one row per oversized release-head path, with its physical line count, package, frozen proposed owner, disposition and confidence. The 359-row frozen map is evidence, not a current count or an implementation instruction.

## Implementation refresh

The [U0 implementation ledger](../u0-owner-ledger-7fe2fca3f.md) supersedes these release counts for
`main@7fe2fca3f`: 378 paths, 21 new, zero retired, with caller/test review evidence and next actions.
The historical release ledger and its 37 ownership domains remain the baseline.

## Reconciliation and assignment rule

- Release census: **357** tracked UTF-8 text paths above 500 physical lines; **355** intersect the frozen 359-row map, **two** are new tests. The four retired GitHub cache/dashboard paths are excluded and credited to the released base, not U8.
- Assignment audit: `357` distinct manifest paths, `357` distinct census paths, equal sets, no duplicate or unassigned path. The script [build.py](build.py) generates the manifest from both source CSVs and asserts the expected sets.
- Each row has exactly one **write owner** below. Package boundaries are ownership domains, not instructions to open one 22-file PR. A worker may use a short sequence of reviewed, green PRs within its package; only one active writer may touch a package at a time. The actual split must follow semantic responsibility and preserve the original public entry point until callers move.
- U0 owns the baseline and transitional gate. U8 packages can start on disjoint paths after U0 assignment review; shared paths wait for the owning U1–U7 contract. U9 owns final census, universal gate and integrated CLI/TUI acceptance. No package has a permanent size exemption.

## Package ledger

| Package | Paths | Accountable boundary | Start prerequisite | Targeted validation |
| --- | ---: | --- | --- | --- |
| `AGENT_CORE` | 9 | Agent identity, model choice and process evidence | U4 contract | model/environment behavior, retained log contents, source/agent tests |
| `AGENT_TURN` | 16 | Turn, queue and shared app-server lifecycle | U4 turn/pause contract | blocked-turn/queue delivery, shared port/approval protocol and focused runner tests |
| `ANALYTICS` | 4 | Offline analytics reducer, renderer and fixtures | U6 telemetry schema | fixture equivalence, deterministic reducer/render snapshots |
| `APP_BOOT` | 2 | Production application startup order and supervision | U0/U2 startup contract; U5 access-child order | rest-for-one restart ordering, boot/restart and release-head behavior |
| `BO_DESIGN` | 5 | Build Order design record and offline prototypes | design-authority decision | offline openability, design-manifest hashes or approved replacement, deep links |
| `BO_PUBLISH` | 15 | Build Order publication authority, receipt and demo packs | U0 fixture/receipt decision | published bundle equality, receipt validation, explicit demo config and offline checks |
| `BO_RUNTIME` | 16 | Build Order graph, pack status and web projection | U2 graph contract; U6 status contract | graph/pack/provider tests and rendered Build Order page |
| `BROWSER` | 5 | Dashboard styles, voice client and browser/docs fixture server | U6 web contracts | CSS assembly parity, real browser and executable fixture-server checks |
| `BUILD_GATE` | 4 | Build gate and holder contract | U0 transitional gate | failure and recovery cases; 500/501 census via U0 gate |
| `CE` | 19 | Pinned Compound Engineering vendor bundle | U0 provenance overlay decision | reconstruct from public upstream pin plus overlay; manifest and license diff |
| `CI` | 2 | Required CI and npm release workflow | U0 gate; U9 release contract | docs-only, merge-group and main required job; release-package smoke |
| `CLAUDE` | 7 | Claude coding agent and Remote Control | U4 backend contract | remote session and telemetry tests; actual TUI when user-facing |
| `CLI` | 10 | Shared aiur/aiurdev launcher and agent control CLI | U1 P0 check; U4/U6 controls | both entry points, packaging, stop/restart and CLI tests |
| `CODEX` | 5 | Codex dynamic tools, turn events and startup evidence | U4 privacy/retry decision | tool scope, event rendering, ANSI-secret redaction, retry age and restart proof |
| `CONFIG` | 4 | Config parser and init contract | U0 config key baseline | schema/init tests, examples and config docs where changed |
| `DECISIONS` | 11 | Decision journal, projection and API | U6 authority matrix | ambiguous fsync, projection failure, restart replay, event-ID uniqueness |
| `DECK_DESIGN` | 1 | Verbatim upstream Stream Deck design extract | U0 design-authority/re-extract decision | upstream byte parity and both consumer interfaces before edits |
| `DECK_PKG` | 9 | Physical Stream Deck package and generated lockfile | package-manifest/lockfile decision | device tests, npm ci offline/release parity, artifact layout |
| `DECK_WEB` | 9 | Stream Deck web bridge, projection and emulator | U6 web contract; DECK_PKG interface | channel/live/browser emulator tests and rendered controls |
| `DOCS` | 7 | Operator/reference docs and docs-app lockfile | owning behavior contracts; lockfile decision | links/anchors, docs build and dependency resolution |
| `EVENTS` | 20 | Event ingestion, webhook ingress, publication, subscriptions and wake inbox | U3 ordering contract; U5 GitHub read contract | interleaving, replay, webhook admission/poller equivalence and alert tests |
| `GH_ACCESS` | 20 | GitHub transport, quota, caches and poll reads | U5 access contract | complete/held/unknown, pagination, quota ledger and cache tests |
| `GH_GUARD` | 6 | GitHub command/budget guards and broker | U5 access contract; GH_ACCESS API | guard and broker tests; credential and runtime broker parity |
| `GH_TRUST` | 10 | GitHub issue authority, CODEOWNERS and dispatch | U5 trust contract | membership revocation, pagination, sanitized body and authority tests |
| `HIST_CE` | 22 | Historical CE plans and brainstorm archives | U0 path/anchor archival policy | old Git blob links, heading fragments and inbound refs |
| `HIST_PRODUCT` | 6 | Historical src/docs plans and brainstorm archive | U0 path/anchor archival policy | legacy elixir/docs aliases, heading fragments and inbound refs |
| `LAYOUT` | 4 | Authored ELK layout worker and pinned release copies | U0 offline asset/hash decision | generated-copy equality, CSP/offline and layout browser tests |
| `LIFECYCLE_DISPATCH` | 22 | Ticket dispatch, retries and command routing | U2 state contract | lease, label, retry and dispatch tests; live transition witness |
| `LIFECYCLE_STATUS` | 25 | Ticket state, status, membership and reconciliation | U2/U6 state projection contract | restart/fence/age tests, CLI/web values and current-run tests |
| `LINEAR` | 1 | Linear adapter and feature reachability | U7 integration-03 decision | active caller/config census, adapter behavior and docs before any cut |
| `OPENCODE` | 12 | OpenCode panes, terminal AgentList, slots and live conversation | U1 P0 check; U4 backend contract | list navigation/ANSI, slot/session tests and foreground TUI chat-pane proof |
| `SITE` | 3 | Marketing website source and generated lockfile | website dependency decision | build, npm ci/offline resolution and rendered page |
| `SKILLS` | 7 | Aiur operator skills and helper scripts | U0 operator contract; BO_PUBLISH API | skill-content contract, reference links and script behavior |
| `TELEMETRY` | 14 | Usage ledger, run telemetry and metering views | U6 aggregate/freshness contract | restart/price tests, observed age and rendered values |
| `TEST_HARNESS` | 5 | Shared test harness and reset | U0 test isolation contract | harness/reset and focused use from multiple domains |
| `WEB` | 13 | Dashboard and operator control center live views | U6 status/presenter contract | rendered unknown/stale age, dashboard browser and focused live tests |
| `WORKSPACE` | 7 | Repository checkout and workspace ownership | U2 lifecycle contract; U7 workspace decisions | retry-safe provisioning, ownership tests and bootstrap regression |

**Total: 357 paths in 37 packages.** Small packages mark distinct authority or artifact boundaries; `LINEAR` is one file because cutting an external adapter requires a separate U7 reachability decision. They are assignments, not promised standalone tickets.

An independent boundary review retained the 357-path census and corrected 11 provisional assignments. It separated production application boot from the shared test harness, the verbatim Stream Deck design extract from the package, and domain tests from generic agent, GitHub access, or harness buckets. These corrections change ownership only; they do not establish a behavior-preserving implementation seam or authorize file deletion.

## Conflict and sequencing notes

- `BO_PUBLISH` owns both `docs/build-order/scripts/publication_*` and mirrored `.claude/skills/aiur-build/scripts/publication/*` oversized paths. Establish the canonical publication/receipt authority before changing the 7,822-line snapshot. `BO_RUNTIME` consumes the published pack; it must not redefine receipt authority.
- `GH_ACCESS`, `GH_GUARD` and `GH_TRUST` may proceed in parallel only after U5 names the shared API. `GH_ACCESS` owns broker read semantics, `GH_GUARD` owns governed process calls, and `GH_TRUST` owns issue/CODEOWNERS command authority. Any shared `website/docs-app/apis/github.md` edits serialize through `DOCS` after the behavior PR is fixed. Read that page before GitHub work.
- `LIFECYCLE_DISPATCH` and `LIFECYCLE_STATUS` use U2 state and transition contracts. The `state.ex` write is dispatch-owned; status consumers may read it but require an agreed interface before implementation. U6 owns status field meaning and observed age.
- `APP_BOOT` owns `src/lib/aiur.ex` and its application test, including production startup and restart order. Other runtime packages request child-order changes through this owner. `AGENT_TURN` owns shared app-server tests; `CODEX` owns the Codex dynamic-tool contract. `OPENCODE` owns terminal AgentList behavior and its real TUI gate.
- `DECK_DESIGN` owns the verbatim upstream `streamdeck.design.js` extract, which the design README forbids editing locally. Re-extract or change upstream before revising that byte-parity source. `DECK_PKG` owns device code and its lockfile; `DECK_WEB` owns the web emulator/channel and browser test. `LAYOUT` owns authored ELK worker and both copied vendor assets, subject to hash/offline/CSP parity. `BROWSER` owns the executable dashboard/docs capture fixture and browser/CSS build.
- `EVENTS` owns the webhook HTTP ingress test; `GH_ACCESS` owns transport and reads. Coordinate admission/signature changes across U3/U5 rather than moving ingress tests into a generic access package.
- `DOCS`, `CI`, and `SKILLS` are shared surfaces. Serialize edits to them after the corresponding behavior contract; do not reserve all runtime packages behind a global documentation barrier. `CE` regeneration must preserve the pinned public upstream plus reviewed five-file overlay; local plugin cache is not an authority.
- `WORKSPACE` owns `workspace_and_config_test.exs` as an existing mixed suite. At pickup, move config/Linear/orchestrator cases to their owning tests without cross-package concurrent edits. `TEST_HARNESS` owns `test_support.exs`; domain workers request fixture changes through its owner.

## Rows requiring an explicit decision before editing

- **Low confidence:** 36 active frozen low-confidence rows remain (all four retired rows had medium/high confidence). Keep their `low` marker in the manifest. The 28 historical archive rows follow U0’s path-preserving short-index policy and need link/anchor proof, especially legacy `elixir/docs` references. Do not slice plans by arbitrary line count.
- **Regenerate/remove:** the manifest retains eight `regenerate` and five active `remove` dispositions from the frozen map. Treat these as candidate actions. Build Order JSON is also a publication receipt; prototype HTML has pinned exact bytes and offline behavior; ELK files are hash-checked offline assets; npm/bun locks encode dependency resolution. Their package prerequisites must be settled before removal or regeneration.
- **Demo and fixture JSON:** `croptracker-demo.json` needs the companion `AIUR_BUILD_ORDER_DEMO` config/readers checked; permanent `aiur-build-order.json` must retain explicit-pack behavior. Analytics fixtures require expected reducer output and current test references.
- **New tests:** `src/test/aiur/orchestrator/status_report_test.exs` belongs to `LIFECYCLE_STATUS` (533 lines); `src/test/aiur_web/components/operator_control_center/units_table_test.exs` belongs to `WEB` (513). Both provisional assignments require U0 caller/behavior review.

## Worker acceptance per package

1. Refresh the exact assigned paths and blob counts on the implementation base; census any new >500 paths and assign them before editing. Search imports, dynamic callers, docs and package readers for each semantic seam.
2. Keep each PR green. Preserve behavior with focused existing tests; add a regression test only when it fails with its guarded production hunk reverted in an isolated clean worktree. Run package-specific checks above and required CI.
3. Recount all tracked UTF-8 text from the checked Git commit: old debt shrinks, no new/enlarged >500 path appears, and each finished assigned path is at most 500. Review new or enlarged files above 200 for cohesion.
4. Record before/after physical lines by source, tests, docs and generated assets; distinguish moved lines from removed lines. Claim quota, latency or cost savings only with a measured baseline and actual production population.
5. User-facing package changes need rendered foreground CLI/TUI or browser proof. U9 verifies the integrated release after every package is complete.

## Audit command

```bash
python3 docs/research/refactor-2026-09-26/synthesis/u8-release-007/build.py
```

The generator reads the two research CSVs and rewrites only this proposal's assignment manifest. Its set assertions are the coverage check. Recheck against the final implementation SHA before promotion; this is not a live dispatch ledger.

# Baseline: existing refactor research

Phase A inventory for the modular platform, mobile and watch research
(`../brief.md`). This file reads the prior refactor research. It does not
change that research, and it does not authorize implementation.

Prepared 2026-10-06 from `research/refactor-findings` at `1c3561ca7`
(2026-09-30, 7 commits past merge base `e09dfbdae`) and `origin/main` at
`45a290e30`. Counts and decisions are copied from the cited files; my own
judgments are labeled. Paths are relative to the repository root.

---

## 1. Inventory

### 1.1 Two research generations

There are two separate refactor research efforts. Neither marks the other as
superseded. The September corpus mentions the July pack once
(`docs/research/refactor-2026-09-26/codebase/feature-boundaries.md:404`).

| | July 2026 "production-readiness" pack | September 2026 "evidence-led" research |
| --- | --- | --- |
| Location | `docs/refactor/` (48 files) | `docs/research/refactor-2026-09-26/` (390 tracked files), plus the plan, requirements and index below |
| Dates | Generated 2026-07-06 | 2026-09-26 to 2026-09-30 |
| Code measured | About 58.7k LOC / 162 files; giants re-measured 2026-07-06 | Survey `0972f0297`; frozen review `3339b887`; release checkpoints `v0.0.7` and `v0.0.8` |
| Plan | `docs/plans/2026-07-06-001-refactor-production-readiness-planning-spike-plan.md` (`status: active`) | `docs/plans/2026-09-29-001-refactor-production-readiness-plan.md` (`artifact_readiness: requirements-only`) |
| Requirements | `docs/brainstorms/2026-07-06-production-readiness-refactor-planning-requirements.md`; brief `docs/refactor/fable-planning-prompt.md` | `docs/brainstorms/2026-09-29-aiur-refactor-requirements.md` |
| Index | `docs/refactor/00-overview.md` | `docs/refactor-research-index-2026-09-29.md`; `docs/research/refactor-2026-09-26/README.md` |
| On `main`? | **Yes**, identical to the branch | **No**, branch-only since PR #2921 |
| Ticket docs | Never generated: `docs/refactor/tickets/` does not exist; the ticket index in `00-overview.md` is a placeholder | None: the plan has units, not tickets (`HANDOFF.md` §5: "None were opened for this research") |

### 1.2 July pack files (`docs/refactor/`)

`00-overview.md` (success criteria, deviations, Executor mandate,
issue-conversion protocol, R13 checkpoint; "Approved-at SHA" is still a
placeholder), `target-architecture.md`, `current-architecture.md`,
`feature-inventory.md` plus 18 section files (1,062 `FI-<SECTION>-NNN`
entries), `phasing-and-parallelization.md`, `regression-safety.md`,
`RUNBOOK.md`, `research-arch/` (19 files: `giant-*.md` name maps,
`dup-backends.md`, `dup-infra.md`, `orchestrator-facade-finish.md`,
`agent-background-tasks-spike.md`), `research-history-hotspots.md`,
`research-docs-framework.md`, `research-v2-mechanics.md`, and the brief
`fable-planning-prompt.md`.

Status (my reading of `docs/plans/`): parts of the July orchestrator
decomposition shipped as separate `completed` plans (2026-07-10 to
2026-07-11, §3.1). The `v2` integration branch and the T-NNN backlog were
never enacted. The September plan lands each unit "in a reviewable PR or
small PR series on a refreshed merged main".

### 1.3 September corpus (`docs/research/refactor-2026-09-26/`)

| Path | Content |
| --- | --- |
| `README.md` | Eight research questions; review method; disclosure rules. |
| `HANDOFF.md` | 2026-09-26 Claude-to-Codex handoff; verbatim goal; corrections (§8). |
| `CONTINUATION.md` | 2,429-line checkpoint log, 339 headings, 2026-09-26 to 09-30: review synthesis, gaps, wakes, Stream Deck audio/surface/provider/rendering, duplication and constants census, claim verdicts, test and skills review, file-size requirement (line 2316). |
| `census/`, `meta/`, `gaps/`, `fixes/`, `agents/` | Census; 21 recurring problem classes; idle gaps; merged fixes; agent failure modes (2,442 sessions). |
| `codebase/feature-boundaries.md` | **40 proposed boundaries**, dependency graph, carve order (§2.3). |
| `review/` | 32 units; 1,033 source IDs → 986 canonical findings (`findings.json`); `code-review.md`; `by-boundary.md`; P2/P3 triage. |
| `features/` | 216 features (`features.json`, `feature-inventory.md`, `matrix/*.md`); `loc-reduction.md` (17,944 conditional gross lines). |
| `synthesis/` | `STATUS.md`, problem map, contradictions, `open-questions.md`, `rewrite-requirements.md`, `refactor-constraints.md`, privacy review, `architecture-verification.md`, U0–U8 checkpoint notes, `u8-release-007/`. |
| `tooling/` | Probes and generators, including `privacy_check.py`. |

### 1.4 What is on `main` and what is branch-only (#2921)

| PR | Merged (UTC) | Effect |
| --- | --- | --- |
| #2865 | 2026-09-29 17:11 | Promoted requirements, plan and index to `main`. |
| #2869 | 2026-09-29 17:52 | Clarified released research status (same files). |
| #2912 | 2026-09-30 04:58 | Pinned the plan to 0.0.7 evidence. |
| #2913 | 2026-09-30 05:28 | Linked corrected owner boundaries. |
| #2915 | 2026-09-30 06:52 | Aligned gates with merged main; also edited `website/docs-app/apis/github.md`. |
| #2919 | 2026-09-30 16:04 | Preserved the membership fence in the plan. |
| #2921 | 2026-09-30 17:03 | **Removed** requirements, plan, index and two synthesis notes from `main`: "refactor findings belong on a research branch, not in mainline docs." |

- **Branch-only:** the September corpus, plan, requirements and index.
- **On `main`:** all of `docs/refactor/`; the plans in §3.1 except the
  September plan; the "Build Order membership recovery" text in
  `website/docs-app/apis/github.md` (cited by U5).
- **Pull request:** none, draft or otherwise (`gh pr list --head
  research/refactor-findings --state all` is empty). About 40 sibling
  `origin/research/refactor-*` / `origin/docs/refactor-*` branches hold
  intermediate steps; this branch consolidates them.
- **Untracked:** `docs/research/aiur-mobile-and-platform/` is not committed.

### 1.5 Base commits and releases referenced

Survey `0972f0297`; frozen review `3339b887`; pre-merge candidate
`0299daca`; merged-main checkpoints `04ef05c41`, `220b8f253`, `b4bc11f`,
`ce0d2c450`, `e196b965`, `f9dabd3e`, `fc8270bb`; `v0.0.7` = `465aca643`
(357 tracked text paths over 500 lines); 0.0.8 candidate `ed742aec`; post-#2921
`main` = `8f17b91f`; `v0.0.8` = `ed43c0e9` (published 2026-09-30; still 357).

---

## 2. The prior target architecture

### 2.1 September plan: units U0–U9

Source: `docs/plans/2026-09-29-001-refactor-production-readiness-plan.md`,
"Implementation Units". The plan has ten units, **U0–U9** (not U0–U8): U8 is
the file-size migration and U9 is final acceptance.

| Unit | Exact name | Owner boundary and primary files | Depends on |
| --- | --- | --- | --- |
| U0 | Refresh evidence and establish the size gate | Evidence/baseline: `docs/research/refactor-2026-09-26/`, `scripts/`, CI | Published 0.0.7 baseline; U0 review remains |
| U1 | Validate the merged P0 repairs without a new deletion policy | `src/lib/aiur/opencode/chat_completions.ex`, `src/lib/aiur/open_ai_compat/command_runner.ex`, `packaging/npm/aiur-cli/libexec/aiur-engine.sh` | U0 |
| U2 | Give lifecycle one owner | `src/lib/aiur/orchestrator/`, `src/lib/aiur/current_run_membership/` | U0, U1 |
| U3 | Preserve event and claim ordering | `src/lib/aiur/events/subscription_store.ex`, `src/lib/aiur/executor/claims.ex`, `src/lib/aiur/executor_wake_inbox.ex` | Event and Claims: U0; wake receipt: reviewed Claims contract; exact U2 caller conflict if one arises |
| U4 | Simplify agent turn and backend lifecycles | `src/lib/aiur/agent_runner/`, `src/lib/aiur/claude/`, `src/lib/aiur/codex/` | U2; reviewed U3 Event delivery contract where consumed |
| U5 | Make GitHub outcomes complete and monotonic | `src/lib/aiur/github/`, `website/docs-app/apis/github.md` | U0 |
| U6 | Align durable decisions, usage and status | `src/lib/aiur/decision_store.ex`, `src/lib/aiur/usage_aggregate/`, `src/lib/aiur_web/` | U2; reviewed U3 wake receipt contract where consumed |
| U7 | Cut proved duplicate paths | `docs/research/refactor-2026-09-26/features/`, candidate subsystem paths | Owning U4, U5 or U6 boundary |
| U8 | Retire the universal file-size debt | All 357 release-head >500-line tracked text paths | U0 for disjoint paths; owning U1–U7 unit for shared paths |
| U9 | Prove the whole release and account for actual removal | `scripts/aiurdev`, `src/browser/`, packaging | U1–U8 |

**Dependency order** ("Sequencing and package decision"):

```text
U0 ──► U1 ──► U2 ──► U4 ──┐
 │             └──► U6 ───┴─► U7 ─┐
 ├──► U3 (Event, Claims) ─► U3 wake receipt ─► (U4/U6 where consumed)
 ├──► U5 ─────────────────────────┤
 └──► U8 (disjoint paths; shared paths wait for owning U1–U7) ──► U9
```

U3 was later split into two independent tickets (Event subscription
delivery; Executor claim ownership) and a wake receipt follow-up
(`synthesis/u3-worker-boundary-current-main-2026-09-30.md`). U5 starts after
U0. U8 is a separate track; runtime repairs do not wait for it.

**Package seams:** "Possible eventual package seams are GitHub access,
agent/backend runtime, lifecycle/Executor state, and presentation. They are
options, not four preapproved repositories." The first seam is the
in-process GitHub access contract (KTD11).

**Key technical decisions:**

| ID | Decision (short form) |
| --- | --- |
| KTD1 | 500-line gate for every tracked text file; no permanent exemption (user-directed). |
| KTD2 | Deletion guard and GitHub cache dashboard removals (#2840/#2841) are outside the baseline (user-directed). |
| KTD3 | Ownership and typed outcomes first; split repos only when startup, state, recovery and test contracts move intact. |
| KTD4 | Read models derive from one field owner; render observed age and cause. |
| KTD5 | Store-specific durability; a failed authoritative journal append is never silently accepted. |
| KTD6 | Reconcile external mutation outcomes before retrying. |
| KTD7 | Physical-line counting convention; 201 lines asks for a cohesion reason. |
| KTD8 | A savings claim needs a running baseline, units, counted population, before/after. |
| KTD9 | Degraded CODEOWNERS trust fails closed for unknown people; sanitized bodies stay visible to the Executor. |
| KTD10 | Fsynced `decisions.ndjson` append is authoritative; projection failure marks read models stale. |
| KTD11 | First seam is the existing in-process GitHub access layers; no new service, package or facade by default. |

**Gates:** (1) readiness gates in the Goal Capsule and "Scope boundaries"
(implementation-head validation, behavior checks for provisional decisions,
U0 review of the 357-path owners; "no product-code work is authorized by
this research-only branch"); (2) "Risks and validation gates"; (3)
"Cross-boundary failure contract" (comment authority, decision write, GitHub
access, file-size migration); (4) "Verification Contract" (source scan,
finding disposition, trust and durable-write matrices, first-seam startup,
production-hunk mutation proof, required CI, foreground `scripts/aiurdev
--test` in wrapper tmux, size and savings); (5) "Definition of Done" D1–D8.

Other ID series in use: plan requirements **R1–R14**, flows **F1–F3**,
acceptance examples **AE1–AE7**, done criteria **D1–D8**. The requirements
doc has its own **R1–R10**, numbered differently from the plan.

### 2.2 September U8 package ledger (37 provisional owners)

`synthesis/u8-release-007/proposal.md` and `assignments.csv` give each of 357
paths one write owner. These are migration domains, not product packages:
`AGENT_CORE`, `AGENT_TURN`, `ANALYTICS`, `APP_BOOT`, `BO_DESIGN`,
`BO_PUBLISH`, `BO_RUNTIME`, `BROWSER`, `BUILD_GATE`, `CE`, `CI`, `CLAUDE`,
`CLI`, `CODEX`, `CONFIG`, `DECISIONS`, `DECK_DESIGN`, `DECK_PKG`, `DECK_WEB`,
`DOCS`, `EVENTS`, `GH_ACCESS`, `GH_GUARD`, `GH_TRUST`, `HIST_CE`,
`HIST_PRODUCT`, `LAYOUT`, `LIFECYCLE_DISPATCH`, `LIFECYCLE_STATUS`, `LINEAR`,
`OPENCODE`, `SITE`, `SKILLS`, `TELEMETRY`, `TEST_HARNESS`, `WEB`,
`WORKSPACE`. Relevant here: `EVENTS` (20 paths: ingestion, webhook ingress,
publication, subscriptions, wake inbox), `DECK_PKG`/`DECK_WEB`/`DECK_DESIGN`
(Stream Deck), `BROWSER` (includes the dashboard voice client), `WEB`,
`APP_BOOT`, `CONFIG`, `CLI`.

### 2.3 September boundary survey: 40 boundaries

Source: `codebase/feature-boundaries.md` §1.1, §2, §7 (measured at
`0972f0297`; `synthesis/architecture-verification.md` is authoritative where
they differ). Levels: **core**, **package** (in this repo), **repo**.

| Family | Boundaries (#, code, recommendation) |
| --- | --- |
| A. Foundation | 1 `K` kernel → package `aiur_kernel`; 2 `CFG` config → package `aiur_config` with schema registration; 3 `TRK` tracker → package, split IssueTracker/CodeHost |
| B. Integrations | 4 `LIN` Linear; 5 `GHC` client/credentials; 6 `GHB` budget governor; 7 `GHR` resource store/read cache; 8 `GHD` tracker domain → `aiur_github` umbrella; 9 `ING` event ingestion ("GitHub issue listeners") → package only after a `GitHub.Listeners` process split |
| C. Spine | 10 `BUS` event exchange and subscriptions → package `aiur_events`; 11 (new) signal and telemetry port → kernel-layer package (`Signal.emit/2`) |
| D. Orchestration | 12 `ORC`, 13 `DSP`, 14 `CTL`, 15 `PRL`, 16 `MSG` → core |
| E. Agent execution | 17 agent sandbox (split from `RUN`); 18 `RUN`; 19 `WS`; 20 `CA`; 21 `CDX`; 22 `CLD`; 23 `OAI`; 24 `OC`; 25 `PM`+`USG` |
| F. Executor-facing | 26 `EXE` → `aiur_executor`; 27 `DEC` → `aiur_decisions`, repo later; 28 `PRJ` → `aiur_projections`; 29 `TEL` → `aiur_telemetry`; 30 `BO` → package now, repo candidate |
| G. Surfaces | 31 `CLI` composition root → core; 32 launcher → stays until the control surface is a versioned protocol; 33 `TUI` → `aiur_tui`; 34 `WEB` → `aiur_web` with a web shell; 35 `SD` Stream Deck → sidecar repo candidate, server side with web; 36 `VOX` voice → optional package; 37 `INI` → `aiur_init`; 38 `DEV` → core; 39 skills; 40 website/docs |

**Carve order** (§7): (1) kernel and signal port; (2) Executor attention;
(3) tracker contract and adapter/backend registration; (4) GitHub caching
and budget governor; (5) agent sandbox, workspace; (6) coding-agent contract,
Codex, Claude; (7) accounting, telemetry, projections, Decisions; (8) Build
Order, web shell and dashboard, Stream Deck, voice, init; (9) GitHub
listeners; (10) orchestration and composition root. Repo candidates in
order: Stream Deck sidecar, marketing site, Linear, OpenAI-compat, Build
Order, Decisions, Codex/Claude, `aiur_github`.

**Status:** the plan treats this as a hypothesis (KTD3, KTD11). 35 of 36
measured boundaries form one strongly connected component; the ~62%
upward-edge reduction is "a design hypothesis, not a measured saving"; a
listener supervisor "is an option; one process per source is not an
established requirement" (architecture verification, codebase-03/-06).

### 2.4 July pack architecture (on `main`)

`docs/refactor/target-architecture.md` and `phasing-and-parallelization.md`:
principles (one source of truth per fact, pure policy functions, no M×N
fan-out, behaviour/base owns cross-cutting work, files ≤200 lines, extract at
second usage); name map for 15 giant files (~190 modules); formal
`Aiur.CodingAgent.Backend` `@behaviour` and shared `Aiur.AppServer`;
consolidations (poller skeleton, one `shell_escape`, one sanitizer);
3–5 phases, delayed-open dependents, sub-waves, `v2` branch; gates `make ci`
per ticket, Phase-1 characterization tripwire, R13 human checkpoint (never
recorded as approved).

---

## 3. Existing ticket and plan docs

No refactor **ticket** documents exist (§1.1). These plans may need updating
or citing.

### 3.1 Plans of type `refactor`

| Path (`docs/plans/`) | Title | Status | Main | Scope |
| --- | --- | --- | --- | --- |
| `2026-09-29-001-refactor-production-readiness-plan.md` | Evidence-led Aiur refactor - Plan | requirements-only | no | U0–U9 program. **Primary prior plan.** |
| `2026-07-06-001-refactor-production-readiness-planning-spike-plan.md` | refactor: Production-readiness refactor planning spike | active | yes | Produce `docs/refactor/` and 30–60 tickets; tickets never produced. |
| `2026-07-11-004-refactor-orchestrator-test-seam-conversion-plan.md` | refactor: Convert orchestrator test seams | completed | yes | Orchestrator test seams. |
| `2026-07-11-003-refactor-orchestrator-dispatch-lifecycle-extraction-plan.md` | refactor: Extract orchestrator dispatch and lifecycle glue | completed | yes | Dispatch/lifecycle extraction. |
| `2026-07-11-002-refactor-orchestrator-lifecycle-glue-relocation-plan.md` | refactor: Relocate orchestrator lifecycle glue | completed | yes | Lifecycle glue relocation. |
| `2026-07-11-001-refactor-comment-polling-split-plan.md` | refactor: Split comment polling responsibilities | completed | yes | Comment polling split (`ING`). |
| `2026-07-11-001-refactor-operator-message-concerns-plan.md` | refactor: Split operator message concerns | completed | yes | Operator messaging (`MSG`). |
| `2026-07-10-001-refactor-orchestrator-residual-glue-characterization-plan.md` | refactor: Characterize orchestrator residual glue | completed | yes | Characterization tests. |
| `2026-07-12-007-refactor-executor-terminology-plan.md` | refactor: Rename the aiur-driver role to Executor | completed | yes | Terminology. |
| `2026-07-09-001-refactor-load-concurrency-envelope-plan.md` | refactor: Add load-based concurrency envelope | completed | yes | Concurrency cap. |
| `2026-07-09-001-refactor-fleet-mix-build-gate-plan.md` | refactor: Gate fleet-wide Mix verification | completed | yes | Build gate. |
| `2026-07-09-001-refactor-bound-agent-test-concurrency-plan.md` | refactor: Bound agent test concurrency | completed | yes | Test concurrency. |
| `2026-07-07-001-refactor-structured-agent-log-reader-plan.md` | refactor: Read dashboard logs from structured agent events | completed | yes | Dashboard logs from `agent.ndjson` (R6 log access). |
| `2026-06-16-001-refactor-launcher-unification-plan.md` | refactor: unify aiurdev + aiur launchers into one engine | complete | yes | Shared launcher engine. |
| `2026-05-24-002-refactor-alerts-yaml-glob-keys-plan.md` | refactor: alerts.yaml glob keys + topic-driven matching (Ticket B) | active | yes | Alert matching on bus topics. |

### 3.2 Other plans that mention "refactor"

Relevant to the new buckets:
`2026-05-24-001-feat-event-system-foundation-plan.md` (Ticket A, active; R2;
mentions Tailscale), `2026-05-24-003-feat-dashboard-events-panel-and-security-plan.md`
(Ticket C, active; R2/R3; mentions Tailscale),
`2026-05-27-001-feat-subscriptions-and-inbox-plan.md` (active; R2),
`2026-05-27-002-feat-agent-progress-emits-plan.md` (active; progress events),
`2026-07-12-003-feat-decision-answer-delivery-plan.md` (completed; Commands),
`2026-07-12-004-feat-supervisor-decision-api-plan.md` (active; Commands API),
`2026-08-16-001-fix-agent-subscription-boundary-plan.md` (R2),
`2026-07-11-006-feat-daemon-run-telemetry-plan.md` (active; `TEL`),
`2026-09-27-001-feat-native-muse-plan.md` (backend preserved by plan R8).

Eighteen others mention the word only in passing (2026-05-22 to
2026-09-28). Main-only `2026-10-01-001-fix-operator-refusal-durability-plan.md`
has one mention; its U-IDs are local to that plan.

### 3.3 Proposed ticket-sized splits that exist only as notes

| Proposed ticket | Source | Scope |
| --- | --- | --- |
| U3 Event subscription delivery (`events-webhooks-executor-01`) | `synthesis/u3-worker-boundary-current-main-2026-09-30.md` | Ordered buffered replay; cursor advances after delivery. |
| U3 Executor claim ownership (`events-webhooks-executor-02`) | same | Former owner cannot renew after a successor claim. |
| U3 Wake receipt and replay (`loose-4-04`) | same | Inbox journal, cursor, receipts; after the claims ticket. |
| U0 transitional size gate | `synthesis/u0-500-line-migration-gate-2026-09-29.md` | Gate in required `workflow security`. |
| U8 package work (37) | `synthesis/u8-release-007/proposal.md` | One write owner per oversized path. |
| Stream Deck owner corrections (8 rows) | `synthesis/owner-map-streamdeck-slice-b4bc-2026-09-30.md` | Sidecar runtime, channel, controller, rasterizer owners. |

---

## 4. Mapping to the new brief's Bucket 1

**Covered** = prior boundary, decision and evidence exist. **Partial** =
inventoried without the analysis the brief asks for. **Omitted** = no prior
analysis (not a claim about the code).

### R1 — Modular platform and independently reusable applications

| Brief asks for | Prior coverage | Where |
| --- | --- | --- |
| Component/dependency map | **Covered.** 40 boundaries, boundary matrix, cycles, upward-edge simulation; verified with corrections. | `codebase/feature-boundaries.md` §1–§3; `synthesis/architecture-verification.md`; `synthesis/graph-audit-*.json` |
| Dashboard; listeners and orchestration; build orders | **Covered:** `WEB` #34; `ING` #9 and `ORC`/`DSP`/`CTL`/`PRL`/`MSG` #12–16; `BO` #30 and U8 `BO_*`. | `feature-boundaries.md`; plan U2, U5, U6 |
| Commands | **Partial.** `DEC` #27; Commands page `ui-05`; durability KTD10/U6. No external command interface. | `features/features.json`; plan U6 |
| Public interfaces | **Partial.** "Public surface" lists internal Elixir modules only. | `feature-boundaries.md` §2 |
| Required vs optional dependencies; config ownership | **Partial.** "Depends on" counts; `VOX` called optional; `CFG` schema registration. No matrix. | same, #2, #36 |
| Migration plan | **Covered internally** (carve order; U0–U9). | §7; plan |
| Capability matrix, minimum combinations, client detection of absent modules; mobile package; no monolith leakage | **Omitted.** | — |

Constraint to reconcile, not override: KTD3/KTD11 make package extraction
conditional, and "a count of packages is not a success measure".

### R2 — Standalone shared event bus

| Brief asks for | Prior coverage | Where |
| --- | --- | --- |
| Bus as its own component | **Covered.** `BUS` #10 → `aiur_events`; move `EventTopics`/`AutoSubscriptions` to ORC, `BranchRefStore` to ING; replace `Sanitizer → CodeOwners` with a trust-classifier callback. | `feature-boundaries.md` #10 |
| Producers, consumers, coupling | **Partial.** Fan-in counts; signal port #11 to remove `Alerts`/telemetry fan-in. No per-event catalog. | #10, #11, §6 |
| Event shapes | **Covered at the July snapshot:** 116 `FI-EVT` entries (topic grammar, id stamping, dedup, persistence). | `docs/refactor/feature-inventory/evt.md` |
| Two buses | **Finding, undecided:** `Aiur.PubSub` (104 refs) and `Events.Exchange`; "The package must own both or define which one each fact uses." | #10 |
| Identity, ordering, replay | **Covered:** plan R5, AE2, U3 (`events-webhooks-executor-01`). | plan U3; U3 worker note |
| Executor journal and custom events | **Covered:** `integrations-32` (keep), `integrations-34` (simplify), `cli-35`. | `features.json` |
| Remote-client reconnection, lifecycle, versioning | **Omitted.** Prior work is in-BEAM only. | — |

### R3 — Optional Tailscale integration and configuration

| Brief asks for | Prior coverage | Where |
| --- | --- | --- |
| Is Tailscale mandatory? | **Partial, one finding.** `nonelixir-shell-27` (P2, docs-drift): "The engine auto-detects Tailscale and overwrites AIUR_DEFAULT_DASHBOARD_HOST, contradicting AGENTS.md and the env schema"; cites `tailscale ip -4` in the engine. | `review/findings.json`; `review/p2p3-triage-part-2.json` |
| Dashboard bind | **Partial.** `config-26` Dashboard server bind (`server.*`), keep. | `features.json` |
| URL ownership, discovery, auth, behavior without Tailscale | **Omitted.** | — |

Code-baseline pointers (not verified here): `AGENTS.md` says "no automatic
Tailscale detection", which the finding contradicts. Other mentions:
`.aiur/examples/config.example`, `packaging/npm/aiur-cli/libexec/aiur-engine.sh`,
`website/docs-app/reference/{cli,configuration,optional-optimizations}.md`,
`docs/voice-mode/spec.md`.

### R4 — Existing Cloudflare/GitHub App relay

| Brief asks for | Prior coverage | Where |
| --- | --- | --- |
| Cloudflare integration and domain | **Omitted** in both generations. | — |
| Webhook ingress | **Covered.** `integrations-25` (HMAC `/api/v1/github/webhook`, 72 h delivery log, per-repo delivery mode; raw cut overturned to keep); `config-12`; `ING`; U5 membership contract. | `features.json`; #9; plan U5 |
| GitHub App | **Partial.** `integrations-21` GitHub App auth (installation tokens; daemon writes as `<app>[bot]`), keep. Not linked to Cloudflare. | `features.json` |
| Mobile push / relay suitability | **Omitted.** | — |

Code-baseline pointers (not verified here): the documented domain is
`aiur.dev`. `website/docs-app/apis/github.md:713`: "`hooks.aiur.dev` is this
operator's setup, not a requirement"; "Cloudflare tunnel boundary" (`:741`):
"Cloudflare is transport for the GitHub webhook, not an API Aiur calls";
`cloudflared` dials out. Also `website/docs-app/reference/optional-optimizations.md`,
`docs/measurements/2026-08-17-comment-poll-webhook-reconciliation.md`.

### R5 — Existing ElevenLabs speech-to-text capability

| Brief asks for | Prior coverage | Where |
| --- | --- | --- |
| Independent packaging | **Covered.** `VOX` #36 (`ElevenLabs.*`, `AiurWeb.Voice*`; 9 files, 1,545 lines): "package, optional. Depends only on CFG and the web shell." | `feature-boundaries.md` #36 |
| Feature decisions | **Covered.** `integrations-51` (STT, TTS, quota meter; externalize overturned, keep server-held credential); `ui-07` dashboard voice (cut overturned, keep); `ui-08` realtime STT ("couple STT decision to both active voice surfaces"); `ui-09` quota meter (simplify); `config-33` `elevenlabs.*` (simplify). | `features.json`; `features/matrix/{ui,integrations,config}.md` |
| Findings | `VOX` 3 primary / 7 affected, 0 P0/P1; Stream Deck audio probes. | `review/by-boundary.md`; `review/in-progress/streamdeck-audio-*.json` |
| Capture/transport/transcription/delivery contract; missing-key behavior | **Omitted.** | — |

Note: dashboard dictation (`ui-07`) already exists, so the code baseline must
state what brief E5 adds. Other docs: `docs/voice-mode/spec.md` (Draft),
`website/docs-app/apis/elevenlabs.md`.

### R6 — Stream Deck integration

| Brief asks for | Prior coverage | Where |
| --- | --- | --- |
| Separate package | **Covered.** `SD` #35: `packages/streamdeck` already separate; repo candidate once `key-face-contract.json` and `streamdeck:fleet` are the contract; server side stays with web. `ui-16`: "keep separate sidecar package in monorepo until versioned protocol proves independent release". | #35; `features.json` |
| Hold-to-dictate, targeting | **Covered as features.** `ui-17` mic (keep); `ui-18` Command answering (keep); `ui-15` channel and projections (keep; "fix connection ownership"); `ui-14` emulator (keep); `ui-19` demo mode (cut). | `features.json` |
| Event-organized logs; shared vs hardware interfaces | **Partial.** `ui-15` has a logs projection (event keys + transcript); U8 separates `DECK_PKG`/`DECK_WEB`/`DECK_DESIGN`; channel owner shared with `src/lib/aiur_web/streamdeck_channel.ex`. | `u8-release-007/proposal.md`; `owner-map-streamdeck-slice-b4bc-2026-09-30.md` |
| Findings | `SD` 27 primary / 44 affected; P0/P1 affected `agent-backends-cc-03`, `web-rest-01`, `web-rest-03`, `web-rest-08`. | `review/by-boundary.md` |

Other docs on `main`: `docs/streamdeck-channel.md`,
`website/docs-app/guide/stream-deck.md`, `docs/research/streamdeck-direct-hid-spike.md`,
`docs/research/streamdeck-end-to-end-proof.md`, `docs/research/evidence/streamdeck/`.

**Summary:** R1 internal map covered, client/capability layer omitted
(KTD3, KTD11, U7). R2 in-process covered, remote clients and versioning
omitted (`BUS`, U3). R3 one P2 finding only. R4 webhook and GitHub App
covered, Cloudflare and relay omitted (`ING`, `GHC`, U5). R5 boundary and
keep decisions covered, contract omitted (`VOX`). R6 covered, shared-log
interface partial (`SD`, U8 `DECK_*`).

---

## 5. Prior decisions to preserve, and open questions

### 5.1 Decisions to preserve

User-directed: (1) **500-line hard limit** for every tracked text file, 200
preferred (KTD1; `synthesis/refactor-constraints.md`), including new research
docs and mobile/watch code; (2) deletion guard and GitHub cache dashboard stay
removed and are not savings (KTD2); (3) refactor research stays off `main`
(#2921); (4) private repositories only as counts marked "(private)"
(`README.md`, `HANDOFF.md` §6); (5) no AI attribution in aiur commits or PR
text (`HANDOFF.md` §6). Evidence-led:

6. Ownership before packages (KTD3); first seam in-process (KTD11).
7. Typed complete / held / unknown outcomes with observed age and cause
   (KTD4, plan R2). This matches brief §7 on stale data and absent
   capabilities.
8. Store-specific durability (KTD5, KTD10); reconcile before retry (KTD6);
   fail-closed comment trust (KTD9); measured savings only (KTD8).
9. Both operating modes preserved (plan R1); Muse and existing backends
   preserved (plan R8).
10. Keep decisions (raw cut/externalize overturned) for `integrations-25`,
    `integrations-51`, `ui-07`, `ui-08`, `ui-14`–`ui-18`. Only `ui-19`
    (Stream Deck demo mode) remains a cut.
11. Stream Deck sidecar stays in the monorepo until a versioned protocol
    proves independent release (`ui-16`).
12. Real foreground CLI/TUI acceptance; production-hunk mutation proof.

July decisions still on `main`: name-map contract, backend `@behaviour`
seam, VitePress docs (now `website/docs-app/`), the preserve-or-fix list in
`docs/refactor/feature-inventory.md` "Known wiring gaps and drift".

### 5.2 Open questions left by prior research

| Question | Prior status | Relevance |
| --- | --- | --- |
| Who owns the authoritative ticket transition? | Open; gates U2. | Queue readiness (E1), progress. |
| Does an answered blocking Command restart its stopped ticket across restart? | PR #2927 merged a wake; restart replay unproved. | Phone/watch command response (N6). |
| Degraded CODEOWNERS trust | Decided (KTD9); tests open. | Who may answer remotely. |
| Which store errors stop writes? | Decided for DecisionStore only. | Notification/command durability. |
| First package seam | In-process (KTD11); physical package deferred to U7. | R1 starting point. |
| Which frozen findings still occur on main? | Per-boundary recheck at implementation head. | Every bucket-1 ticket. |
| Historical idle-gap causes | Closed at evidence limit; prospective instrumentation. | Value ordering. |
| Which bus owns which fact? | Raised (`BUS` #10); undecided. | Core R2 decision. |
| Attention routing completeness (`codebase-07`) | Bounded corrections; topic membership ≠ delivery. | Notifications (N4/N5). |
| Linear, Claude REPL/Remote Control, `aiur-build` cuts | Conditional (U7). | Capability matrix. |
| Oversized files to cap | U0/U8 open; 357 at v0.0.8. | Package moves must not add >500 files. |

Never asked by prior research: Tailscale optionality, Cloudflare and relay
purpose, remote client authentication, push notifications, device pairing,
multi-instance discovery, bus versioning for external consumers.

---

## 6. Recommended document conventions for the new scope

### 6.1 Placement

- Put all new work under `docs/research/aiur-mobile-and-platform/` on
  `research/refactor-findings`. Do not edit `docs/refactor/`,
  `docs/research/refactor-2026-09-26/`, or the September plan, requirements
  or index; link to them.
- Pin prior-research citations to `1c3561ca7` (or a later branch SHA).
- Do not promote to `main` (#2921). A draft PR from the branch is acceptable
  if review is wanted.
- Use the brief §10 layout already scaffolded: `baseline/`, `contracts/`,
  `bucket-1-refactor/`, `bucket-2-platform/`, `bucket-3-mobile-watch/`,
  `owner-design-tasks/`, `cross-feature-reviews/`.
- Keep each file at or below 500 lines (KTD1).

### 6.2 IDs (avoid collisions)

Bare `R1`–`R6` already mean different things in the plan (R1–R14) and the
requirements doc (R1–R10). `U0`–`U9`, `KTD1`–`KTD11`, `AE`, `D`, `F`,
boundary codes, U8 package codes, `FI-*` and `cli-/config-/integrations-/
subsystems-/ui-NN` are taken.

| Level | Format | Example |
| --- | --- | --- |
| Project tag | `MP` | — |
| Feature | `MP-<brief ID>` | `MP-R2`, `MP-E1`, `MP-N4` |
| Feature directory | `bucket-<n>-<name>/<ID>-<slug>/` | `bucket-1-refactor/R2-event-bus/plan.md` |
| Chunk | `MP-<ID>.C<n>`, dir `C<n>-<slug>/` | `MP-R2.C1` |
| Ticket | `MP-<ID>.C<n>.T<nn>`, file `T<nn>-<slug>.md` | `MP-R2.C1.T01` |
| Contract | `MP-CT-<name>`, `contracts/<name>.md` | `MP-CT-event-envelope` |
| Owner design task | `DESIGN-<ID>` (brief §8); shared `DESIGN-SHARED-<name>` | `DESIGN-E5` |
| Open question / decision | `MP-Q<nn>` / `MP-KD<nn>` | `MP-Q07`, `MP-KD03` |

Bare `R2` is acceptable inside `bucket-*/` headings only. `MP-KD` avoids
`KTD`; new tickets never use a bare `U` number.

### 6.3 Cross-reference fields for each bucket-1 ticket

- `Prior-units:` September units depended on or amended (or `none`).
- `Prior-boundaries:` codes from `feature-boundaries.md` (e.g. `BUS, ING`).
- `Prior-features:` September feature IDs; July `FI-*` IDs where stronger.
- `Prior-findings:` canonical IDs from `review/findings.json`.
- `Size-owner:` U8 package owning any >500-line file touched.
- `Base-SHA:` implementation commit the ticket was researched against.

### 6.4 Reconciliation notes (my recommendations)

1. Treat MP-R1 and MP-R2 as extensions of KTD3/KTD11 and U3. If MP-R1 needs
   a package before U7 allows it, record an explicit `MP-KD` that amends the
   September plan, with the evidence KTD3 asks for.
2. Treat MP-R3 and MP-R4 as new baseline research; start from the §4
   pointers.
3. MP-R5 and MP-R6 already have keep decisions and boundaries; their work is
   the shared-versus-hardware/provider interface split and absent-capability
   behavior.
4. Add the brief's plan-refresh task mapping September unit paths to the new
   package boundaries.
5. From the new `README.md`, link `docs/refactor-research-index-2026-09-29.md`
   and `docs/research/refactor-2026-09-26/synthesis/STATUS.md` instead of
   restating prior counts.

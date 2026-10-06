# MP-R1 migration plan

Part of the [MP-R1 plan](plan.md). It orders the work that gives each component in
[component-map.md](component-map.md) its boundary, and it reconciles that order with
the prior refactor program instead of replacing it.

## 1. Relationship to the prior program

| Prior artifact | Status here |
|---|---|
| September plan U0–U9 (`docs/plans/2026-09-29-001-refactor-production-readiness-plan.md`, branch-only) | **Kept.** U-units are behaviour-preserving repairs and the file-size migration. MP-R1 does not renumber, reorder or absorb them. Where an MP-R1 move touches a U-unit's owned files, the U-unit's contract lands first (table §3). |
| Carve order, `feature-boundaries.md` §7 (10 steps) | **Adopted** as the backbone of §2. MP-R1 adds three steps (identity/capabilities, web-shell split, client contracts) and slots the new components (build-queue, harness package, listener package, voice, Stream Deck, mobile) into it. |
| KTD3 / KTD11 (ownership before packages; first seam in-process) | **Kept.** Every step below first creates the logical component (manifest entry, facade, checker rule). Physical packaging is a separate, later decision per component (§5). |
| U8 37-owner size ledger (`synthesis/u8-release-007/`) | **Kept.** A move must not create a file over 500 lines; a moved oversized file carries its U8 owner in the ticket's `Size-owner` field. |
| SCC finding (35 of 36 boundaries) | Baseline for the ratchet in MP-R1-C1: violations may only decrease. |

## 2. Ordered steps

Each step is shippable alone and preserves behaviour. "Feature" = which MP feature
executes it; R1 executes only the rows marked R1.

| Step | What | Prior step | Feature | Depends on |
|---|---|---|---|---|
| S0 | Component manifest, schema, dependency checker in the required `lint` job, ratchet baseline; `build-queue` rule usable by MP-E1 | new | **R1-C1** | U0 review of the prior plan (RC-19; X-58). The build-queue rule is pulled forward to wave 0 as MP-E1's own source-scan test (RC-11), which is Bucket 2 and does not wait for U0 |
| S1 | Kernel primitives and signal port (`Signal.alert/2`, `:telemetry`); `Alerts`, `RunTelemetry`, `ObservabilityPubSub` become consumers | §7 step 1 | **R1-C5** | S0 |
| S2 | Identity (machine id, instance id) and capability registry, `GET /api/v1/capabilities`, `aiur capabilities` | new | **R1-C2, R1-C3** | S0 |
| S3 | Event bus package, external subscriber API, which-bus-owns-which-fact | §7 step 1/BUS | MP-R2 | S1 |
| S4 | Executor attention binding repairs | §7 step 2 | prior U3 + MP-E2 | S1 |
| S5 | Tracker contract split (IssueTracker / CodeHost), adapter registration | §7 step 3 | **R1-C7** | S0 |
| S6 | Agent sandbox, workspace | §7 step 5 | **R1-C7** | S0 |
| S7 | Harness adapter package (tool surface out of `Codex`, capability callbacks, Muse included) | §7 step 6 | MP-R7 | S6 |
| S8 | GitHub family umbrella (client, budget, cache, domain) | §7 step 4 | **R1-C7** | S5; prior U5 (GitHub outcomes) |
| S9 | Config schema registration per component | prior #2 | **R1-C4** | S0; runs alongside S5–S8, one section per ticket |
| S10 | Accounting, telemetry, projections, Commands. Commands is **required**; answer delivery stays a synchronous call through a delivery-target port that orchestration implements (MP-R1-C8-T02). The existing `decision.answered` event only wakes the orchestrator; it does not replace the call (CR-C8-3, X-23) | §7 step 7 | **R1-C8** (Commands with prior U6) | S1, S3 |
| S11 | Web-shell / dashboard-ui split; `web-kit` library (`AiurWeb.Kit`, L1); each component owns its `AiurWeb.Routes.<X>` and `AiurWeb.Sockets.<X>` modules and web-shell composes them (downward edges, RC-39) | §7 step 8 (part) | **R1-C6** | S2 |
| S12 | Build orders as a component; voice (MP-R5); Stream Deck server + neutral conversations/anchor API (MP-R6); init | §7 step 8 | **R1-C8** (BO), MP-R5, MP-R6 | S11 |
| S13 | Build queue moved from its wave-0 seam to its final component shape; `Alerts` call → `Signal.alert` | new | **R1-C8** with MP-E1 owner review | S1, S5, S12 |
| S14 | Client contracts package `packages/aiur-contracts` (schemas from `contracts/`), `R-client` check | new | **R1-C3** | S2, S3 |
| S15 | GitHub listeners out of the orchestrator process | §7 step 9 | **R1-C9** | S3, S8 |
| S16 | Orchestration core: state field owners, effects, `AgentControlCLI` split by component, per-component CLI verbs | §7 step 10 | **R1-C9** | everything above |
| S17 | Plan refresh: regenerate the path map (§4) against the merged head and update every later-wave ticket | new | **R1-C11** | each of S1–S16 merges; final run after S16 |
| S18 | Component directory page goes live (MP-REQ4, D20) | new | **R1-C10** | S16, S17, DESIGN-R1 approved |

**Gate on every step (X-58, RC-19).** RC-19 keeps the prior plan's "U0 review before
code work" for refactor work. Every MP-R1..R7 ticket therefore waits for U0 review,
including the Bucket-2-enabling chunks inside them (R1-C2/C3, RC-12; R2-C5..C7, RC-09),
because they ship in the refactor sequence. There is no ticket ID for U0, so the gate is
stated here, in each plan and in the tickets READMEs, not in `blocked_by`. The
MP-R1-C11-T02 implementation-head recheck does not replace it. MP-E1 is Bucket 2 and is
not gated on U0.

**Planned components added by later features (X-29).** These have manifest rows with
`status: planned` from S0, so the checker and the directory page (S18) can name them.
R1 does not build them; their features do.

| Component | Added by | Lands in | First step that must allow for it |
|---|---|---|---|
| `listener-modes` (required send router) and `listener-spec` (build-time input) | MP-E7 (C1–C3, wave 3) | core `Aiur.Listener.*`; `src/priv/listener_spec/` | S16: orchestration's `AgentChat.send/3` delegates to `Aiur.Listener.send/3`; orchestration implements `Aiur.Listener.DeliveryTarget` |
| `machine-gateway` (gateway process + `aiur_machine` store library) | MP-N2 | new process beside the instances | S2: reads `identity.json`; never part of an instance's supervision tree |
| `relay-service` | MP-N4 | `services/push-relay-service` (separate service) | none in `src/`; covered by the `services/` ownership scope |
| `notification-policy` (policy + preferences store) | MP-N5 | L3 component | S3 (bus catalog), S12 (build-orders progress) |

Concurrency inside wave 1 (value-and-sequencing.md): S1, S2, S5, S6 can start in
parallel after S0; S3 (R2) and S7 (R7) run in parallel; S9 rides along; S15 and S16
are last. §7 step 9 may move ahead of S6 if the prior gaps study shows the
GitHub-read queueing in `Dispatcher` is a real idle cause (prior §7 note, unchanged).

## 3. Interlocks with prior U-units

| MP-R1 step | Prior unit that owns the same files | Rule |
|---|---|---|
| S1 (journal primitive out of `DecisionLog`) | U6 (`decision_store.ex`) | U6's journal outcome matrix lands first; S1 moves the primitive without changing fsync or append semantics (KTD5, KTD10). |
| S3 (bus) | U3 (`events/subscription_store.ex`, `executor/claims.ex`, `executor_wake_inbox.ex`) | U3 ordered-replay and claim-ownership tickets land first; MP-R2 builds on them. |
| S8 (GitHub) | U5 (`src/lib/aiur/github/`) | U5 typed outcomes first; KTD11 says this is the first seam. |
| S10 (Commands) | U6 | Same as S1. |
| S16 (orchestration) | U2 (lifecycle owner) | U2's single lifecycle owner is a precondition; S16 does not decide who owns the ticket transition. |
| S7 (MP-R7) | U4 (harness routing, incl. Gemini through draft #2870) | MP-R7-C3 rebases onto U4 (prior plan); the Gemini/ACP row follows RC-22. (X-60) |
| S5, S13 (tracker split, build-queue move) | U2 (`dispatcher.ex`, `issue_sync.ex`) | MP-R1-C7-T07 and C7-T08 touch the Dispatcher; they rebase over U2 and over MP-E1-C1's hooks and keep them (RC-19, RC-20). (X-60) |
| All | U8 | No new file over 500 lines; record `Size-owner`. |

## 4. Path map (plan-refresh input)

Later-wave tickets (MP-E2 … MP-N7) are researched against `45a290e3` paths. This map
is what MP-R1-C11 regenerates after each move, so implementers do not rediscover it.
"Target" paths are proposals until the move merges.

| Row | Today (`45a290e3`) | Target component (path after move) | Moved by | Affects tickets of |
|---|---|---|---|---|
| PR-01 | `src/lib/aiur/events/{exchange,publisher,topic,…}.ex` | event-bus (`aiur_events`) | S3 | E1, E2, E4, N4, N5 |
| PR-02 | `src/lib/aiur/codex/dynamic_tool/**` | harness-adapters tool surface | S7 | E2 (native capture), E7 |
| PR-03 | `src/lib/aiur/{codex,claude,muse,open_ai_compat}/**`, `coding_agent/**`, `app_server/**` | harness-adapters | S7 | E2, E3, E7 |
| PR-04 | `src/lib/aiur/eleven_labs/**`, `aiur_web/voice_*.ex` | voice-stt | S12 (MP-R5) | E5, E6, N6, N7 |
| PR-05 | `aiur_web/streamdeck_logs.ex` (anchor rule) | conversations (neutral name) | S12 (MP-R6) | E4, N6 |
| PR-06 | `decision*.ex`, `decision_store/**`, `asks*.ex` | commands (`aiur_decisions`) | S10 | E2, E5, N4, N6 |
| PR-07 | direct `Aiur.Alerts.*` calls | `Signal.alert/2` | S1 | E1, E2, every feature raising attention |
| PR-08 | `aiur_web/router.ex` single router | web-shell router + registered component routes | S11 | E3, E4, E5, N2, N4, N6 |
| PR-09 | `config/schema.ex` embeds | per-component section modules | S9 | every feature adding config |
| PR-10 | `build_order/**`, `aiur_web/build_order*` | build-orders | S12 | E1, N3, N5 |
| PR-11 | `src/lib/aiur/build_queue/**` (wave 0) | build-queue (final) | S13 | N3, N5 |
| PR-12 | `orchestrator/comment_polling*.ex`, `events/github_*.ex`, cursor fields in `Orchestrator.State` | github-listeners | S15 | E1 (merge events), N5 |
| PR-13 | `agent_control_cli.ex` verbs | per-component CLI modules | S16 | E1 (queue verbs), E2, E3, N2 |
| PR-14 | `live_conversation*.ex`, `agent_event_feed.ex`, `agent_log.ex` | conversations | S10/S12 | E3, E4, E6 |
| PR-15 | none | `packages/aiur-contracts` | S14 | every client feature (N1–N7, R6 sidecar) |
| PR-16 | `~/.config/aiur/instances/*.instance` (launcher) | unchanged path; identity reads `machine/identity.json` beside it | S2 | N2, N3 |

Contract rows (not paths) that the refresh also re-checks: `MP-CT-identity-and-capabilities`
version, the event envelope (MP-R2), the Command payload (MP-E2), the conversation
anchor (MP-E4).

## 5. Promotion test: when a logical component becomes a physical package

A component moves to its own Mix app / npm package / repository only when all hold
(KTD3 made concrete):

1. Zero allowlisted dependency violations in or out of it for 2 consecutive merged
   releases.
2. Its child specs, boot order and restart strategy are declared by the component
   and assembled by the composition root (no knowledge of its internals in `aiur.ex`).
3. Its durable state, recovery and migration code moves with it, and its tests run
   without booting the whole application (prior #38: 221 test files are `async: false`
   because they share one app).
4. Its config section is owned in the manifest (`owns.config`; S9). After MP-R1-C4-T05
   (RQ4) sections stay literal `embeds_one` in the root schema, so "owned" means declared
   in the manifest, not moved; e.g. `Config.Schema.ElevenLabs` stays in core `config` and
   the voice package owns `elevenlabs` as manifest data (MP-R5-C2-T02/C3-T01).
5. A second consumer exists or is planned (Khala for listener-modes, the mobile app for
   `aiur-contracts`), or independent release is a stated need (Stream Deck, `ui-16`).

**Physical form (Phase D; answers CR-R7-1 and RQ-R5-PKG).** A promoted Elixir component
is an in-repo Mix project under `packages/elixir/<app>/` (sibling of `packages/streamdeck`),
added to `src/mix.exs` as a path dependency (`{:aiur_harness, path:
"../packages/elixir/aiur_harness"}`). `src/` does not become an umbrella. `mix release`
includes path dependencies as applications automatically, so the release keeps one boot.
An optional component (for example voice-stt) is a path dependency that the release
includes by default; "core without it" is proven by a CI job that compiles and tests
`src/` with the dependency removed. The first promotion (MP-R7-C4-T03) proves the form
with its release boot check (MP-R7-C4-T05); MP-R5-C3-T01 uses the same form.

Candidates in order, unchanged from prior §7 plus the new ones: `aiur-contracts` (first;
it is a client dependency), Stream Deck sidecar (already a package), listener-modes
(shared with Khala, MP-Q1), Linear, OpenAI-compat, build-orders, commands, Codex and
Claude adapters, the `aiur_github` family. The mobile app is a separate package from
day one (MP-R1-KD4); it is not "promoted" because it never lived in `src/`.

## 6. Rollback

Every step is a move behind an unchanged facade, so rollback is a revert of that PR.
The checker allowlist is part of the PR; reverting restores it. No step migrates
on-disk state formats; a step that would (e.g. moving `decisions.ndjson`) must keep the
path through `Config.Paths` and is out of MP-R1 scope.

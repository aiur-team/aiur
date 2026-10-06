# Phase B reconciliation

Written by the coordinator on 2026-10-06, after all 11 feature planners finished. Each item names the conflict, the decision and the owner of the follow-up.

- **Coordinator** decisions are engineering calls that Phase C tickets must follow.
- **Owner** items are product calls, recorded in the named `DESIGN-*` task. They stay open until Kevin answers them.

## Coordinator decisions (binding for Phase C)

| ID | Conflict | Decision |
|---|---|---|
| RC-01 | MP-R1 creates `identity.json` at first daemon boot; MP-N2 creates it at `aiur mobile enable`. | **First daemon boot**, path `~/.config/aiur/machine/identity.json`. MP-N2 reads it and never creates a second identity. |
| RC-02 | MP-N2 uses `instance_ref`; MP-R1 uses `instance_id`. | **`instance_id = <machine_id>/<instance_key>`** everywhere. `instance_ref` is retired. |
| RC-03 | The brief says "global machine configuration"; `~/.aiur/config` is the fallback *workflow* config (`workflow.ex:84-93`). | Machine-level settings (mobile, pairing, relay) live in a new **`~/.aiur/machine`** file, after the `~/.aiur/alerts` pattern. `~/.aiur/config` is unchanged. |
| RC-04 | The identity contract had no owner in the MP-R2 view. | **MP-R1 owns `contracts/identity-and-capabilities.md`**. MP-R1 also takes MP-N1's additions: a per-boot ID, a minimum client version, and a typed "capability unavailable" error. |
| RC-05 | **Wave conflict.** D15 routes dashboard sends through listener mode (MP-E7, wave 4), but MP-E3/E4 are wave 3, and the E4 send path depends on E7-C3. | Move **MP-E7-C1 to C3** (spec package, mode store, route every send through the mode) into **wave 3, ahead of the E3/E4 write chunks** (E3-C5, E4-C6). The E3/E4 read chunks are not blocked. E7-C4 to C7 stay in wave 4. The default change from interrupt to `sync` (E7-D6) is an owner item, so E7-C3 ships behind a flag that keeps today's behaviour until DESIGN-E7 is approved. |
| RC-06 | MP-R6-C1 and MP-E4-C7 both move the `StreamdeckLogs` anchoring. | **MP-R6-C1 extracts** the neutral anchor module without changing behaviour. **MP-E4-C3 extends it** (exact anchors, stable entry IDs, durable journal positions). E4-C7 shrinks to switching the Stream Deck onto the E4 journal. |
| RC-07 | Anchor address: row index (today), stable entry ID (MP-R6), or journal position (MP-E4). | The **E4 durable journal position** is the address. The stable entry ID is the position number that the journal writer assigns. The bus only reserves an `anchor` field (MP-R2). |
| RC-08 | New bus topics are requested by several features. | MP-R2's catalog (R2-C5) registers all of them: `ticket.<id>.agent.decision.human-needed` (E2; spelling per the command contract), `ticket.<id>.pr.closed_unmerged` and `ticket.<id>.issue.closed` (E1), `ticket.<id>.agent.listen-mode.changed` (E7), `ticket.<id>.queue.*` and `system.queue.*` (E1), `system.build_order.<root>.progress` (producer: **MP-E1-C7**). |
| RC-09 | MP-R2-C5 to C7 (catalog, export journal, external read API) add capability inside a refactor feature. | They stay under MP-R2, are **tagged Bucket-2 enabling work**, are off by default, and are scheduled just before their first consumer (MP-N4/N5). |
| RC-10 | MP-N5 needs 10% steps; the MP-E1 contract emits only 25/50/75/100 milestones (A-E1-1). | MP-E1-C7 also exposes a **progress read API and an internal progress-changed signal**. Milestone events stay at 25%. N5 computes per-device thresholds from the signal. The D18 default stays 25%. |
| RC-11 | MP-E1 ships in wave 0, before MP-R1's dependency checker. | MP-E1 ships **its own source-scan test** that the queue never references `Aiur.Orchestrator`. R1-C1 absorbs it later. R1's component map adds two narrow edges: a rank and hold lookup in `DispatchPolicy`, and a claim-check interface that orchestration implements (E1 X-1). |
| RC-12 | Should identity and the `/api/v1/capabilities` endpoint (R1-C2/C3) count as refactor work? | **Bucket-2 enabling work inside MP-R1**: it adds an API, not behaviour. The DESIGN-R1 gate covers its operator surfaces. |
| RC-13 | Voice config namespace. | Speech-to-text keeps **`elevenlabs.*`** (MP-R5 preserves behaviour). New conversational keys go under **`voice.conversation.*`** (MP-E6). |
| RC-14 | MP-R5 message names versus the voice-session contract. | The voice-session contract adopts R5's `{:voice_transcript, :voice_error, :voice_closed}` and the availability reasons `:unconfigured` and `:not_installed`. |
| RC-15 | **HTTPS prerequisite.** The dashboard serves plain HTTP only (`http_server.ex:64,147`). iOS ATS and Android cleartext rules block it, and the in-WebView mic needs a secure context. | Becomes a shared research and owner item, **RQ-TRANSPORT**, owned by **MP-N2** (transport policy) with MP-R3 (docs and bind guards). Every N1, N6 and N7 ticket that loads the dashboard depends on it. The owner choice is DESIGN-N2 §transport: tailnet HTTPS via `tailscale cert` (which publishes machine names to Certificate Transparency logs) or a pinned self-signed certificate. |
| RC-16 | Native clients cannot use the voice socket (CSRF, browser session, `dashboard_writable`; `voice_socket.ex:21-37`). | MP-E5 adds a **device-authenticated voice path** that uses N2 device tokens. It is consumed by N6 and N7. |
| RC-17 | The watch app's location (open question in MP-R1). | The watch apps live **inside `packages/aiur-mobile`** (MP-N1). |
| RC-18 | MP-E2 reports that a structured Command the Executor ignores is never escalated. | This is MP-E2-C2's job. Live bug #2819 is the legacy-attention variant: its re-ask never stops. The fix ticket is in flight, and E2-C2 cites it. |

## Owner items (open; listed in the design gates)

- **Executor default listener mode:** `sync` (D13) or `steer` (DESIGN-E3 and DESIGN-E7, E7-D6).
- **MP-Q1 package home:** a spec-first package published from the Khala repo, which Khala must make public (DESIGN-E7, E7-D1).
- **App publisher and default relay operator:** paid Apple and Firebase accounts (DESIGN-N4, OQ-N4-1). This is the main mobile blocker.
- **Distribution:** private only, or a public store listing that needs a demo mode (DESIGN-N1).
- **Paid validation spikes:** ElevenLabs Agents (E6-OQ9), an Expo throwaway prototype (MP-N1), and native ask-the-user spikes (E2 C4-T00 and C5-T00, both free).
- **Whether to enable the Codex `default_mode_request_user_input` flag** in production (DESIGN-E2).

## Live bugs found during Phase B (filed)

- #3009: `CurrentRunProjections` ignores the observability broadcast.
- #3010: `dashboard_writable` defaults to `true`, but the router comments say it is disabled by default.
- Not filed, in a sibling repo: `aiur-claude` `turn/steer` drops the steered text (`server.ts:194/466-469/505`). aiur does not call it yet. Recorded as MP-R7 research and as a precondition of E7-C4.

## Prior refactor plan (U0–U9) against the pack

These were found while cross-linking the U0–U9 plan. They are coordinator decisions.

| ID | Conflict | Decision |
|---|---|---|
| RC-19 | MP-E1 (wave 0) edits U2 files (`issue_sync.ex`, `dispatch_policy.ex`) and U5 files (`github/labels.ex`, `github/issues.ex`). The prior plan blocks product code until U0 review. | That U0 gate covers refactor work only. MP-E1 is Bucket 2 and ships first by operator choice (D2). It is **not gated on U0**, and it limits its core edits to the MP-E1-C1 hooks. The U2 and U5 tickets must rebase over E1-C1 and keep its hooks. |
| RC-20 | U2's exit criterion says "no second label writer remains"; MP-E1 adds the queue as an `agent:todo` writer. | The queue is a **sanctioned caller of the single label-writer seam**. Before U2 lands it calls the existing labels module. After U2 it calls U2's writer. U2's exit criterion means "no second label-*writing implementation*", not "one caller". |
| RC-21 | The order of MP-R2-C2-T02 (`TrustClassifier` around `Sanitizer`) and U5 (the KTD9 trust snapshot) is unstated. | **U5 first.** R2-C2-T02 consumes U5's trust snapshot and does not define its own trust rules. |
| RC-22 | U4 and R8 route Gemini through draft PR #2870; MP-R7's adapter set omits Gemini and ACP. | MP-R7 adds a **Gemini/ACP row** to its harness inventory. It is conditional on #2870: if #2870 merges first, R7-C2 declares Gemini's delivery capabilities; if not, the row records it as a future adapter. |
| RC-23 | The U8 size ledger is pinned at `465aca643`; the pack is pinned at `45a290e3`. | Each ticket looks up its size owner **when it starts**, against the then-current U8 ledger. This is part of the MP-R1-C11 plan-refresh ticket. |

## Phase C decisions

| ID | Conflict | Decision |
|---|---|---|
| RC-24 | MP-R1-C5-T03 and MP-R1-C8-T04 both move `AiurWeb.ObservabilityPubSub` out of the web layer. | **C5-T03 owns the move.** C8-T04 drops its item 1 and depends on C5-T03. |
| RC-25 | MP-E3-C5 (Executor composer, wave 3) depends on MP-E7-C6 (hook delivery into the Executor session, wave 4). | E3-C5 ships in wave 3 with the **composer disabled and an explanation**, as the E3 plan already allows. A follow-up enables it when E7-C6 lands. |
| RC-26 | Closed-unmerged PR detection: MP-E1 reads the stored webhook delivery, and MP-R2 CR-R2-6 asks E1 to produce the topic. | R2 registers `ticket.<id>.pr.closed_unmerged`. **E1 produces it** from the same stored-delivery observation. Detection works in webhook mode only, and the E1 docs must say so. |
| RC-27 | MP-E1 tickets say the CLI reference is machine-checked. | That is wrong. `website/docs-app/scripts/check-cli-reference.sh` exists only as an npm script, and no CI workflow runs it (checked on `origin/main`). AGENTS.md is correct as written. The E1 docs tickets keep the manual docs requirement. |

## Phase D graph decisions

Source: `cross-feature-reviews/graph-check.md`.

| ID | Problem | Decision |
|---|---|---|
| RC-28 | MP-E5-C3-T02 and MP-E6-C7-T02 each block the other. | E6 Converse UI depends on E5's mic-choice UI. **Drop the E5 → E6 edge.** |
| RC-29 | MP-E5-C8 (device voice path, wave 4) needs MP-N2 device tokens (wave 5). | **MP-E5-C8 moves to wave 5**, after MP-N2-C6. |
| RC-30 | MP-E6-C7-T01 (dashboard Converse) pulls in about 20 MP-N2 tickets through MP-E5-C8-T01. | **Drop the edge.** Dashboard Converse uses the browser voice path, so device voice is not a prerequisite. |
| RC-31 | RC-09 put MP-R2-C5 (topic catalog) just before N4/N5, but MP-E6-C4-T05 and MP-E7-C2-T05 consume it in wave 4. | **MP-R2-C5 moves to the start of wave 4.** C6 and C7 (export journal, external API) stay just before N4/N5. This amends RC-09. |
| RC-32 | Spikes and measurements (E2-C4-T00, E2-C5-T00, E3-C3-T01, E4-C1-T00) have no gate. | These are read-only research or local experiments, so they carry `design_gate: n/a — research spike`. The brief allows research before approval; it only forbids implementation. |
| RC-33 | MP-N6-C4-T02 to T04 lack DESIGN-N6. | **Add DESIGN-N6.** |
| RC-34 | Ticket ID spelling is mixed: MP-R1 uses `T1`, every other feature uses `T01`. | **Normalize to `T01`** in file names and in every reference inside the pack. |
| RC-35 | No wave-2 ticket depends on MP-R1-C11-T03 (the final plan refresh). | The first MP-E2 tickets (C1-T01, C2-T05, C3-T01) **gain a dependency on MP-R1-C11-T03**, which enforces "refactor before features" (D1). |

## Phase D review decisions (binding for the fix pass)

| ID | Finding | Decision |
|---|---|---|
| RC-36 | X-01: the listener package is optional but routes every core send. | Split it in two. The **send router lives in core** as a required part of orchestration, under `Aiur.Listener.*`. The **shared spec package** (the Khala-published JSON spec and fixtures, MP-Q1) is a build-time input. If the vendored spec is absent or fails its checksum, the router uses today's routing (the `:legacy` mode from RC-05) and reports capability `listener_modes` as `unavailable` with a reason. The spec is never a runtime dependency. |
| RC-37 | X-02: three definitions of a "live Executor". | **Live means `active` or `idle`.** `stalled`, `expired` and `absent` are not live, and D9's "no live Executor, go to the human" applies to them. The identity contract and the pairing summary's ranking change to match. The phone shows `stalled` with its own label, but routing treats it as not live. |
| RC-38 | X-03: two watch snapshot schemas (16 KiB and 32 KiB). | **MP-N7-C1-T01 owns the schema**, with a 16 KiB budget. MP-N1-C3-T04 and the client capability model §7 reference it and do not define it. |
| RC-39 | X-04: optional components depend upward on `web-shell`. | **Invert the dependency.** `web-shell` gets a route and socket registration seam, and each component registers its routes, so the component no longer imports the web layer. MP-R1-C6 owns the seam, and the component map edges change to match. |
| RC-40 | X-05: build-order progress lives in the optional build queue. | **`Aiur.BuildProgress` belongs to the `build-orders` component.** MP-E1-C7 still writes it, and the queue is one of its producers. MP-N5's build-order notifications check `build_orders`, not `build_queue`, so D18's defaults work without the queue. |
| RC-41 | Security B2: relayed answers can supersede direct operator answers. | **Precedence: direct operator > operator_relayed > Executor.** A relay never supersedes or revises a direct operator answer, and never answers an Executor-originated Command. `actor_source` records the real entry point. These match live PR #3006 rework. |
| RC-42 | Security B1: any same-user agent can pair itself and gain operator authority. | This becomes an owner item (DESIGN-N2 Q8) with three options. The pairing contract gains a threat section, and the store gains an integrity alert for device rows that have no journal entry. The recommendation goes in DESIGN-N2. |

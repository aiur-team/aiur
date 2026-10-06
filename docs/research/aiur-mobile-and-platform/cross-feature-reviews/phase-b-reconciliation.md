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
| RC-08 | New bus topics are requested by several features. | MP-R2's catalog (R2-C5) registers all of them: `ticket.<id>.decision.human-needed` (E2), `ticket.<id>.pr.closed_unmerged` and `ticket.<id>.issue.closed` (E1), `ticket.<id>.agent.listen-mode.changed` (E7), `ticket.<id>.queue.*` and `system.queue.*` (E1), `system.build_order.<root>.progress` (producer: **MP-E1-C7**). |
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
- **Paid validation spikes:** ElevenLabs Agents (E6-OQ9), an Expo throwaway prototype (MP-N1), and native ask-the-user spikes (E2 C4-T0 and C5-T0, both free).
- **Whether to enable the Codex `default_mode_request_user_input` flag** in production (DESIGN-E2).

## Live bugs found during Phase B (filed)

- #3009: `CurrentRunProjections` ignores the observability broadcast.
- #3010: `dashboard_writable` defaults to `true`, but the router comments say it is disabled by default.
- Not filed, in a sibling repo: `aiur-claude` `turn/steer` drops the steered text (`server.ts:194/466-469/505`). aiur does not call it yet. Recorded as MP-R7 research and as a precondition of E7-C4.

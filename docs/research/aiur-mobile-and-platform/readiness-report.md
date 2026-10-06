# Readiness report

The closing report of the research pack (brief §10). Base `45a290e3`, research date
2026-10-06. The index is [README.md](README.md); the graph numbers come from the final
[graph-check.md](cross-feature-reviews/graph-check.md).

## Verdict

**The whole scope is planned, reviewed and reconciled. Nothing is ready to build yet.**
Every one of the 525 tickets has the nine brief §9 sections, the dependency graph is
clean (0 dangling references, 0 cycles, 0 missing gates, 0 wave inversions), and every
Phase D review finding has a resolution. Every implementation ticket still waits on its
feature's DESIGN gate and on Kevin's authorization to implement.

- **Can start first, after one approval:** wave 0, MP-E1 (build queue), after DESIGN-E1.
  Eight tickets have no other blocker.
- **Planned and design-blocked only:** the refactor (MP-R1–R7, also behind the U0 review
  of the prior plan) and platform features MP-E1–E5 and MP-E7.
- **Planned, but feasibility is not yet proven:** MP-E6 (paid provider spike) and all of
  bucket 3 (MP-N1–N7). These must not be called ready until the prototype, the spike,
  the transport decision and the physical-device runs pass. They depend on owner
  accounts that do not exist yet.

## 1. What is sufficiently planned

All 21 features have a plan, chunks, a tickets README, a DESIGN gate and tickets with all
nine brief §9 sections (a mechanical scan of all 525 ticket files finds no missing
section and no "add appropriate tests" wording). Each was read by at least one Phase D
reviewer, and the depth review deep-read 87 tickets (≥ 4 per feature where that many
exist).

| Feature | Tickets | §9 sections | Reviewed by | Planning status |
|---|---|---|---|---|
| MP-R1 Modular platform | 69 | 69/69 | consistency, UX/depth | planned; design-blocked; U0 gate |
| MP-R2 Event bus | 38 | 38/38 | consistency, security (C7), UX/depth | planned; design-blocked; U0 gate |
| MP-R3 Optional Tailscale | 2 | 2/2 | consistency, security, UX/depth | planned; design-blocked; U0 gate |
| MP-R4 `hooks.aiur.dev` boundary | 1 | 1/1 | consistency, UX/depth | planned; also waits on prior unit U8 |
| MP-R5 Voice package | 9 | 9/9 | consistency, UX/depth | planned; design-blocked; U0 gate |
| MP-R6 Stream Deck | 3 | 3/3 | consistency, UX/depth | planned; design-blocked; U0 gate |
| MP-R7 Harness adapters | 21 | 21/21 | consistency, UX/depth | planned; design-blocked; U0 gate |
| MP-E1 Build queue | 41 | 41/41 | consistency, feasibility, UX/depth | planned; design-blocked |
| MP-E2 Commands and escalation | 36 | 36/36 | all four | planned; spikes C4-T00/C5-T00 can run first |
| MP-E3 Executor communication | 20 | 20/20 | consistency, security, UX/depth | planned; design-blocked |
| MP-E4 Conversations and anchors | 20 | 20/20 | all four | planned; measurement C4-T00 can run first |
| MP-E5 Dashboard voice | 19 | 19/19 | consistency, feasibility, security, UX/depth | planned; design-blocked |
| MP-E6 Voice assistant | 31 | 31/31 | all four | planned; **provider unproven** (paid spike) |
| MP-E7 Listener package | 33 | 33/33 | consistency, security, UX/depth | planned; package home and npm publish owner items |
| MP-N1 Phone app | 31 | 31/31 | all four | planned; **framework unproven** (prototype) |
| MP-N2 Pairing | 39 | 39/39 | all four | planned; **transport and same-user threat are owner decisions** |
| MP-N3 Meta-dashboard | 16 | 16/16 | consistency, feasibility, UX/depth | planned; waits on N1/N2 |
| MP-N4 Encrypted push | 34 | 34/34 | all four | planned; **publisher accounts and device runs** |
| MP-N5 Notification preferences | 17 | 17/17 | consistency, feasibility, UX/depth | planned; waits on N4 |
| MP-N6 Command response | 20 | 20/20 | all four | planned; waits on N1/N2/N4, E2, E4 |
| MP-N7 Watch apps | 25 | 25/25 | consistency, feasibility, UX/depth | planned; **device runs DV-W*** |

`status: ready` (121 tickets) means "researched and fully specified", not "can start
now"; 104 of them still have an open ticket predecessor (README, review T-10).

## 2. What is blocked on Kevin

### 2.1 DESIGN gates (21)

Every implementation ticket waits on its own gate except four research spikes
(`design_gate: n/a`, RC-32). Tickets blocked per gate (graph count):

| Gate | Tickets | Gate | Tickets | Gate | Tickets |
|---|---|---|---|---|---|
| [DESIGN-R1](owner-design-tasks/DESIGN-R1.md) | 72 | [DESIGN-E1](owner-design-tasks/DESIGN-E1.md) | 41 | [DESIGN-N1](owner-design-tasks/DESIGN-N1.md) | 42 |
| [DESIGN-R2](owner-design-tasks/DESIGN-R2.md) | 38 | [DESIGN-E2](owner-design-tasks/DESIGN-E2.md) | 46 | [DESIGN-N2](owner-design-tasks/DESIGN-N2.md) | 47 |
| [DESIGN-R3](owner-design-tasks/DESIGN-R3.md) | 2 | [DESIGN-E3](owner-design-tasks/DESIGN-E3.md) | 24 | [DESIGN-N3](owner-design-tasks/DESIGN-N3.md) | 21 |
| [DESIGN-R4](owner-design-tasks/DESIGN-R4.md) | 1 | [DESIGN-E4](owner-design-tasks/DESIGN-E4.md) | 22 | [DESIGN-N4](owner-design-tasks/DESIGN-N4.md) | 43 |
| [DESIGN-R5](owner-design-tasks/DESIGN-R5.md) | 9 | [DESIGN-E5](owner-design-tasks/DESIGN-E5.md) | 29 | [DESIGN-N5](owner-design-tasks/DESIGN-N5.md) | 17 |
| [DESIGN-R6](owner-design-tasks/DESIGN-R6.md) | 5 | [DESIGN-E6](owner-design-tasks/DESIGN-E6.md) | 36 | [DESIGN-N6](owner-design-tasks/DESIGN-N6.md) | 27 |
| [DESIGN-R7](owner-design-tasks/DESIGN-R7.md) | 22 | [DESIGN-E7](owner-design-tasks/DESIGN-E7.md) | 35 | [DESIGN-N7](owner-design-tasks/DESIGN-N7.md) | 32 |

Counts include tickets that cite another feature's gate. The refactor gates (R1–R7) are
mostly "confirm no user-facing change" boxes; the bucket 2 and 3 gates hold the real UX
decisions. Refactor tickets also wait on the **U0 review** of the prior plan (RC-19),
which has no ticket ID; the Executor checks it before dispatch.

### 2.2 The nine owner decisions to answer first

All 164 owner questions, each with a recommendation, are in
[owner-questions.md](cross-feature-reviews/owner-questions.md). A recommendation is advice,
not a decision. These nine unblock the most work (§0 of that file):

| # | Decision | Owner gate | Recommendation | Unblocks |
|---|---|---|---|---|
| P1 | Who publishes the store apps and operates the default push relay | DESIGN-N4 D-8 (OQ-N4-1) | aiur-team organisation Apple and Firebase accounts, and an aiur-team hosted relay | MP-N4-C2-T06/T07, C7-T02, MP-N1 distribution, the prototype (P9) |
| P2 | HTTPS for paired devices: public cert (T-A) or self-signed + SPKI pin (T-B) | DESIGN-N2 §transport | **T-A** (`tailscale cert`): the only option with the WebView mic and LiveView WebSockets on iOS | RQ-TRANSPORT: 31 tickets in N1, N2, N3, N5, N6, N7 |
| P3 | Private or public distribution | DESIGN-N1 D-N1-2 | Private first (TestFlight / Play internal) | 6 tickets; demo mode only if public |
| P4 | Devices available for physical validation | DESIGN-N1 D-N1-8 | List them; minimum oldest-supported iPhone, current iPhone, Pixel-class Android 13+ | 7 tickets; unlisted rows report "not validated" |
| P5 | Authorize the paid ElevenLabs Agents spike | DESIGN-E6 E6-OQ9 | Authorize | MP-E6-C1, C2-T03 |
| P6 | Package home for the listener spec | DESIGN-E7 E7-D1 | Spec + TS reference + fixtures, published from Khala (RC-36) | 5 MP-E7 tickets |
| P7 | Listener mode lifetime | DESIGN-E7 E7-D5 | Per ticket run | MP-E7-C2-T01 |
| P8 | Backend-only MP-E2 tickets may start before DESIGN-E2 approval | DESIGN-E2 §6 item 9 | Confirm | MP-E2-C1, C2, C3 store parts |
| P9 | Authorize the throwaway Expo prototype | DESIGN-N1 OWNER-AUTH-N1-PROTO | Authorize, after P1 names the Apple account | MP-N1-C9-T01, MP-N2-C10-T04, N1-C5 device checks |

Also high-impact, not in the nine: **DESIGN-N2 Q8** (same-user agents can pair
themselves, security B1; recommendation (c) agent deny rules + integrity alert by
default, (a) separate OS user documented as hardening) and **DESIGN-E7 E7-D8**
(Executor default listener mode; recommendation `steer` for the Executor only).

### 2.3 Authorizations required (money, accounts or external effects)

| Authorization | Where | Blocks | Recommendation |
|---|---|---|---|
| Paid ElevenLabs Agents spike | DESIGN-E6 E6-OQ9; MP-E6-C1-T01 | the MP-E6 adapter (C2-T03) and RQ-E6-1..6 | Authorize |
| Throwaway Expo prototype (Apple Developer Program cost) | DESIGN-N1 OWNER-AUTH-N1-PROTO; MP-N1-C9-T01 | framework confirmation before 40+ N1 tickets | Authorize after P1 |
| Apple Developer and Firebase accounts; relay publisher and operator | DESIGN-N4 D-8; MP-N4-C2-T06, C7-T02 | any TestFlight or store build, any real push | aiur-team organisation accounts and hosted relay |
| First npm publish of the Khala listener package | DESIGN-E7 OWNER-NPM-FIRST-PUBLISH; MP-E7-C1-T03 | the published listener spec | Set up npm trusted publishing (no long-lived token) |
| Codex `default_mode_request_user_input` flag (stage `UnderDevelopment`) | DESIGN-E2 §6 item 10 | native Codex question capture in production | Keep off until spikes MP-E2-C4-T00 and C5-T00 show the turn is held without a timeout |
| Optional: NSE filtering entitlement | DESIGN-N4 (OQ-N4-3) | cleaner retraction and silent drop | Apply only if retraction matters in the device run |

## 3. What remains technically unverified

### 3.1 Open research questions that block tickets

| Item | Question | Tickets | Settled by |
|---|---|---|---|
| RQ-TRANSPORT (RC-15) | HTTPS policy for paired devices | 31 | owner P2, then MP-N2-C10-T05 device run |
| RQ-U2-TRANSITION, RQ-U6-STATUS-MODEL | prior-plan units U2/U6 transition and status model | 2 + 1 (MP-R1) | the prior plan's U2/U6 work |
| RQ-R7-5 | promotion criteria for the first harness package | 1 | MP-R7 at implementation |
| RQ-E3-5 | Claude `Notification` hook matchers for "waiting for input"; Codex equivalent | 1 | MP-E3 spike / implementation |
| RQ-E6-1..6 | ElevenLabs Agents auth, latency, events, tools, cost | MP-E6-C2-T03 and the adapter | paid spike MP-E6-C1-T01 |
| RQ-N4-2, -5, -7, -8, -9 | watch shows NSE-decrypted text; NSE can remove delivered notifications; relay cost; Cloudflare Worker APNs; Android force-stop detection | 1 each | device rows V-W1, V-I6; measurement; dated developer.android.com page |
| N1-RQ3 | watch + NSE targets survive `expo prebuild --clean` with entitlements | 1 | Expo prototype |
| RQ-N7-6 | daemon STT and provider accept watch audio faster than real time | 2 | DV-W6 |

Citations still marked for re-verification: MP-E7-C4-T02 (Codex docs, to pin at an
`openai/codex` SHA, T-11) and MP-N7-C2-T06 (SwiftUI notification controller inherits
`notificationActions`; UNVERIFIED until DV-W10).

### 3.2 Spikes and measurements not yet run

| Ticket | What it settles | Cost |
|---|---|---|
| MP-E2-C4-T00 | Codex `request_user_input` through aiur's app-server frames | free, local |
| MP-E2-C5-T00 | Claude `AskUserQuestion` capture under aiur-claude | free, local |
| MP-E3-C3-T01 | Codex TUI rollout fixtures at 0.160.x, hook `transcript_path` | free, local |
| MP-E4-C1-T00 | journal entries and bytes per hour per agent on the live fleet | free, read-only |
| MP-E6-C1-T01 | ElevenLabs Agents as the conversational provider | **paid** (P5) |
| MP-N1-C9-T01 | Expo + native cores + watch + NSE feasibility | **paid account** (P9) |

### 3.3 Physical-device validation (none run)

| Ticket | Rows |
|---|---|
| MP-N4-C7-T02 | the canonical [device-validation-plan.md](bucket-3-mobile-watch/MP-N4/device-validation-plan.md) (39 rows: V-I*, V-A*, V-K1, V-LS1, V-NS1, V-M4, V-R5 …) |
| MP-N1-C10-T01 | [device-validation.md](bucket-3-mobile-watch/MP-N1/device-validation.md) shell rows DV-P1–P4, DV-P11, DV-P12 (run with MP-N4-C7) |
| MP-N2-C9-T02, MP-N2-C10-T05 | pairing, relink, revoke, unpair-all; ATS, cleartext, LiveView socket, WebView mic secure context |
| MP-N7-C6-T01, C6-T02 | Apple Watch DV-W1..W6, W9..W13; Wear OS DV-W2..W8, W12, W13 |

Until these pass, bucket 3 is "planned", not "complete". A row with no listed device
reports "not validated" rather than passing (P4).

## 4. What becomes eligible first after each approval

From [dependency-map.md](dependency-map.md). These tickets have no ticket predecessor and
no other open blocker; each starts once the gate is approved **and** Kevin authorizes
implementation. Refactor (R) tickets also need the U0 review.

| Approval | First eligible tickets |
|---|---|
| DESIGN-E1 | MP-E1-C1-T01, C1-T03, C1-T04, C1-T05, C1-T06, C2-T01, C3-T01, C7-T01 |
| DESIGN-R1 | MP-R1-C1-T01, MP-R1-C2-T01 |
| DESIGN-R2 | MP-R2-C1-T01..T06, C2-T04, C4-T05; C6-T01 (scheduled in wave 5) |
| DESIGN-R3 | MP-R3-C1-T01, MP-R3-C2-T01 |
| DESIGN-R5 | MP-R5-C1-T01, C4-T01, C4-T02 |
| DESIGN-R6 | MP-R6-C1-T01 |
| DESIGN-R7 | MP-R7-C1-T01, C1-T02, C1-T03, C5-T02 |
| DESIGN-E6 | MP-E6-C6-T01 |
| DESIGN-E7 + DESIGN-R7 | MP-E7-C4-T01 (aiur-claude, cross-repo) |
| DESIGN-N2 | MP-N2-C2-T03, MP-N2-C3-T01 |
| DESIGN-N4 | MP-N4-C2-T01 (relay skeleton) |
| none (research spikes, RC-32) | MP-E2-C4-T00, MP-E2-C5-T00, MP-E3-C3-T01, MP-E4-C1-T00 |

Next after one named owner item: MP-R4-C1-T01 (U8), MP-E6-C1-T01 (P5), MP-E7-C1-T01
(E7-D1), MP-E7-C2-T01 (E7-D5), MP-N1-C9-T01 (P9). Gates with no immediately eligible
ticket: DESIGN-E2 (its entry tickets wait on MP-R1-C11-T03, RC-35), E3, E4, E5, N1, N3, N5,
N6, N7 and R4.

**Recommended first wave: wave 0, MP-E1 after DESIGN-E1.** The eight tickets above start
in parallel; the longest MP-E1 chain is 11 tickets. In parallel, and at no cost, run the
four research spikes. Then wave 1: R1, R2 and R7 start together after their gates and U0.
The value order still applies: approving a later gate early does not mean its tickets
should start before earlier waves end.

## 5. Recommendations summary

| Area | Recommendation | Evidence |
|---|---|---|
| Phone framework (N1) | **React Native + Expo CNG**, the per-instance dashboard reused in a WebView, two small native cores (Swift: iOS, NSE, watchOS; Kotlin: Android, FCM, Wear OS). Runner-up KMP + Compose; Capacitor, Flutter, PWA rejected. Confirmed only by the throwaway prototype (P9) and DESIGN-N1. | [MP-N1 plan §4](bucket-3-mobile-watch/MP-N1/plan.md), [framework-evidence.md](bucket-3-mobile-watch/MP-N1/framework-evidence.md) |
| Notifications and relay (N4) | **Sealed alert pushes** (HPKE X25519/ChaCha20-Poly1305 + Ed25519 signature, one key per device per machine) sent outbound to a **thin opaque relay** with no accounts, then APNs/FCM. The phone decrypts on device (iOS NSE; Android data message) and fetches context only on open. Apple, Google and the relay see one uniform fallback string. Publisher and operator: P1. | [MP-N4 plan §6](bucket-3-mobile-watch/MP-N4/plan.md), [notification contract](contracts/notification-destination-and-payload.md) |
| Voice provider (E6) | **ElevenLabs Agents**, built-in LLM, client tools, **daemon-held websocket**; the assistant only drafts, the human confirms (button only, never speech). Default daily cap 60 min. Subject to the paid spike. | [MP-E6 plan §3](bucket-2-platform/MP-E6/plan.md), [provider-research.md](bucket-2-platform/MP-E6/provider-research.md) |
| Watch (N7) | **Native, phone-dependent** apps: SwiftUI watchOS inside the iOS app over WatchConnectivity; Compose for Wear OS over the Data Layer. Notifications, compact Command card, options, explicit Dictate or Converse; no orchestration control. System dictation by default; uniform-fallback forward is accepted with the card one tap away (D-N7-10). | [MP-N7 plan](bucket-3-mobile-watch/MP-N7/plan.md), [DESIGN-N7](owner-design-tasks/DESIGN-N7.md) |
| Listener package home (E7) | **Spec-first package in the Khala monorepo**: JSON Schema, scheduler table, goldens and a TS reference; aiur vendors the spec at a pinned version and runs the goldens against its Elixir code (RC-36). Executor default mode `steer`, workers `sync`. | [MP-E7 plan](bucket-2-platform/MP-E7/plan.md), [listener-mode contract](contracts/listener-mode.md) |

## 6. Security posture

The model: the aiur machine is never publicly reachable; paired devices reach it over a
private path (Tailscale) with machine-level pairing; content leaves the machine only
sealed to a device key.

- **B1 — a same-user agent can become "the human"** (RC-42). Agents run as the same OS
  user, so they could read `machine_key`, add a `devices.json` row and answer
  `human_required` Commands. Addressed by: a threat section
  ([pairing security sibling §S1](contracts/pairing-and-instance-registry-security.md));
  an integrity check that alerts on any device row with no `paired` journal entry
  (MP-N2-C1-T03/T04, `Store.integrity/0`); the threat stated at `aiur mobile enable`; and
  the owner decision DESIGN-N2 Q8 (recommendation: agent deny rules + integrity alert by
  default, separate OS user documented as the full fix). **Residual risk remains until
  Kevin picks an option;** pairing protects against network attackers and lost phones,
  not against a determined local agent.
- **B2 — a relayed answer could replace a direct operator answer** (RC-41, the #3006 bug).
  Addressed by precedence `direct operator > operator_relayed > Executor` in the command
  contract §6, `actor_source` on every answer, rank-based `ConflictSummary.for/2`, and
  must-fail tests in MP-E2-C3-T01, C6-T01 and MP-N6-C1-T03.
- **Other controls from the review:** per-instance store watchers so revocation reaches
  every daemon (M1); LiveView sockets disconnected on revoke (M2); transport restrictions
  and the HTTP-degraded mode off by default (M3); `actor_source` defaulting to `:rpc`
  (M4); conversation reads require a `principal:` and device-bound entries are masked
  (M5); provenance for provider input (M6); domain-separated signatures
  `aiur-qr-v1` / `aiur-registry-v1` / push (m6); lock-screen privacy option (D-10, m9);
  scanner-only pairing links (m10); loopback is defence in depth, the hook token is the
  boundary (m10).

## 7. Cross-review findings and their resolution

| Review | Blocker | Major | Minor | Status |
|---|---|---|---|---|
| [Consistency and modularity](cross-feature-reviews/review-consistency-modularity.md) (X-01..X-61) | 5 | 26 | 30 | **All resolved.** X-16, X-33, X-34, X-38 and X-49 were closed in the final pass; the rest by the four fixers |
| [Feasibility and failures](cross-feature-reviews/review-feasibility-failures.md) (M1–M8, m1–m10) | 0 | 8 | 10 | **All resolved.** Owner picks for M3 (reminder), M5 (watch fallback) and M8 (cost cap) are recorded as recommendations in DESIGN-N5, N7 and E6 |
| [Privacy and security](cross-feature-reviews/review-privacy-security.md) (B1, B2, M1–M6, m1–m10) | 2 | 6 | 10 | **All resolved in the pack.** B1 leaves an owner decision (DESIGN-N2 Q8) |
| [UX gates and ticket depth](cross-feature-reviews/review-ux-and-ticket-depth.md) (G-1..G-10, T-1..T-13) | 5 | 17 | 1 | **All resolved.** The two gate contradictions (X8, X9) are now single-owner recommendations awaiting Kevin |

Fixer records: the four fix logs in [cross-feature-reviews/](cross-feature-reviews/). The
45 cross-fixer handoffs: 9 applied in the final pass, 36 already done, 0 rejected
([fix-handoffs-applied.md](cross-feature-reviews/fix-handoffs-applied.md)). Phase B
reconciliation RC-01..RC-42 are all applied. Nothing from a review is open except owner
decisions and the unverified items in §3.

## 8. Implementation status

**Nothing was implemented.** The research changed only files under
`docs/research/aiur-mobile-and-platform/`; the uncommitted working tree outside the pack is
clean. No production code, no configuration, no GitHub issue or label, and no
daemon state was changed. All "PROPOSED" paths and modules in tickets do not exist yet.

Research commits on `research/refactor-findings`:

- `d455b86ea` — Plan the modular platform, mobile and watch research pack
- `cc77fa387` — Research every chunk into implementation-ready ticket docs
- the commit that adds this report (`git log -1 -- readiness-report.md`) — Phase D: cross-reviews, fixes, final graph, index and readiness report

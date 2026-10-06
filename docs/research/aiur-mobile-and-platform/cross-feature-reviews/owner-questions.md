# Owner questions — the single de-duplicated list

Regenerated in the Phase D fix pass (fixer `ux`), 2026-10-06, base `45a290e3`. Source: the
21 gate files in [`../owner-design-tasks/`](../owner-design-tasks/) after the fix pass,
[phase-b-reconciliation.md](phase-b-reconciliation.md) § Owner items and RC-36…RC-42, and
the four Phase D reviews.

How to read this list:

- **One row per question, listed once, under the gate that owns it.** A question that
  another gate also touches appears only under its owner; the other gate links to it
  (§1 lists every such link).
- **Rec** is the recommendation now written in the owning gate file, with its one-line
  reason. Every question has one. A recommendation is engineering advice for Kevin, **not a
  decision**: nothing is decided until Kevin answers in the gate file.
- **Blocks** names the tickets or chunks held by the answer, where the pack names them.
- IDs are the gate's own IDs. Where a plan uses another ID, both are shown.
- Confirmation boxes ("no user-facing change") are counted as one question per gate.

**Counts:** 21 gates, **164 questions**, each with a recommendation (rows that say "See P/X" point to the one owning row and are not counted twice). The 5 questions that
two gates used to ask (X1, X3, X5, X6, X7) and the 2 contradictions (X8, X9) now have one
owner each.

## 0. Answer these first

| # | Question | Owner | Rec (and why) | Blocks |
|---|---|---|---|---|
| P1 | Who publishes the store apps and operates the default push relay | DESIGN-N4 **D-8** (OQ-N4-1) | **aiur-team organisation accounts + an aiur-team hosted relay** — any TestFlight or store build needs one publisher, and an organisation identity does not tie signing and push credentials to one person | MP-N4-C2-T06, C2-T07, C7-T02, MP-N1 distribution, MP-N1-C9-T01 (via P9) |
| P2 | HTTPS for paired devices: T-A public cert (`tailscale cert`; name goes to CT logs) or T-B self-signed + SPKI pin | DESIGN-N2 §transport | **T-A** — the only option with the WebView mic and LiveView WebSockets on iOS | RQ-TRANSPORT: 31 tickets across N1, N2, N3, N5, N6, N7 |
| P3 | Distribution: private (TestFlight / Play internal) or public listings | DESIGN-N1 D-N1-2 | **Private first** — public needs a demo mode and App Review 2.1(a) / 4.2 | 6 tickets; demo mode (D-N1-7) |
| P4 | Devices available for physical validation | DESIGN-N1 D-N1-8 | **List them; minimum: oldest-supported iPhone, current iPhone, Pixel-class Android 13+** — each platform minimum needs a real device | 7 tickets; unlisted slots report "not validated" |
| P5 | Authorize the paid ElevenLabs Agents spike | DESIGN-E6 E6-OQ9 | **Authorize** — the adapter's event mapping cannot be built from docs alone | MP-E6-C1, C2-T03 |
| P6 | Package home for the listener spec (MP-Q1) | DESIGN-E7 E7-D1 | **Accept: spec + TS reference + fixtures, published from Khala** — shares behaviour with no runtime dependency (RC-36) | 5 MP-E7 tickets (wave 3, RC-05) |
| P7 | Mode lifetime: per ticket run or per agent session | DESIGN-E7 E7-D5 | **Per ticket run** — a respawn should not silently reset a chosen mode | MP-E7-C2-T01 |
| P8 | Backend-only MP-E2 tickets may start before DESIGN-E2 approval | DESIGN-E2 §6 item 9 | **Confirm** — they add no user-facing surface | MP-E2-C1, C2, C3 store parts |
| P9 | Authorize the throwaway Expo prototype (Apple Developer Program cost) | DESIGN-N1 OWNER-AUTH-N1-PROTO | **Authorize, after P1 names the Apple account** — retires framework risk before 40+ N1 tickets build on it | MP-N1-C9-T01, MP-N2-C10-T04, N1-C5 device checks |

## 1. Questions that more than one gate touches — one owner each

| ID | Question | Owner (answer here) | Linked from | Rec |
|---|---|---|---|---|
| X1 | Executor default listener mode | DESIGN-E7 **E7-D8** | DESIGN-E3 decision 2 (= OQ-E3-3) | **`steer` for the Executor only; workers stay `sync`** — Executor turns are long, so `sync` could hold a message for a whole loop |
| X2 | Global default change from interrupt to `sync` | DESIGN-E7 E7-D6 | — | **Accept, plus a per-message "send now" (`steer`)**; E7-C3 ships behind a flag until answered (RC-05) |
| X3 | How long a stopped or crashed instance stays listed | DESIGN-N2 **Q6** | DESIGN-N3 Q4 | **7 days** — covers a weekend away, keeps the list short |
| X4 | App icon badge | DESIGN-N5 **D-9** | DESIGN-N3 Q5 | **On by default: open blocking Commands that need you, summed across machines** |
| X5 | Converse on the watch, or hand off to the phone | DESIGN-N7 **D-N7-3 / D-N7-4** | DESIGN-N6 D-3 | **Turn-based, 4 s median target; "Continue on phone" if missed** |
| X6 | Multi-question native Commands layout | DESIGN-E2 **§6 item 5** (dashboard and phone) | DESIGN-N6 D-4 (watch fallback only) | **One card per question, single Submit**; watch shows "Answer on phone" |
| X7 | Command option labels inside the encrypted push payload | DESIGN-N4 **D-7** | DESIGN-N7 D-N7-9 | **No labels; the card opens** — keeps option text off the lock screen |
| X8 | HTTP-degraded mode (no HTTPS) | DESIGN-N2 **§transport** | DESIGN-N1 D-N1-6 | **Off by default, opt-in diagnostics only**, restricted to loopback / Tailscale ranges (security M3). *Was a contradiction:* N1 had "allow with warnings". Recommendation only |
| X9 | Voice package not installed: hide the mic, or show it disabled | DESIGN-R5 **§2** | DESIGN-E5 E5-OQ4 (keeps the no-key half) | **Shown disabled with the reason** — matches the no-key copy and the pack's capability rule; keeps MP-R5 independent of MP-E5-C2. *Was a contradiction:* E5 had "hidden". Recommendation only |
| X10 | Which Commands count in banner, badge and notifications | DESIGN-E2 **§6 item 2** | DESIGN-N3 §1 count field, DESIGN-N5 D-4 / D-9 | **Every open Command visible; only "Needs you" counts and notifies** |

## 2. Bucket 1 gates

### DESIGN-R1 — modular platform, component directory

| ID | Question | Rec |
|---|---|---|
| R1-§1 | Confirm no runtime change; keys unchanged; no new setup step; Bucket-2 enabling work appears as component capabilities, not planned features | Confirm — those are shipped APIs, not features |
| R1-S1 | `aiur capabilities [--json]` exists; its wording | Exists, read-only, same data as the API |
| R1-S2 | `GET /api/v1/capabilities` exists | Exists; dashboard auth now, device auth later |
| R1-S3 | `identity.json` at first daemon boot; label visibility | First boot; label only in `aiur capabilities` |
| R1-S4 | API-without-pages run shape: operator flag or internal | Internal only; `--no-dashboard` unchanged |
| R1-S5 | Capabilities concept page and CLI entry wording | Approve when drafted (ships with C3) |
| R1-Q1 | Directory entry: minimal or full | Full; env var names only — "what do I need for X" is the page's job |
| R1-Q2 | Sidebar placement | Under "Reference" |
| R1-Q3 | Grouping | By operator goal, "optional only" filter |
| R1-Q4 | Publicity of planned features | Name + one line + "planned"; no IDs, dates, order |
| R1-Q5 | Which planned features to list | Only those whose DESIGN gate is approved |
| R1-Q6 | Dependency diagram | One small minimum-combination diagram |
| R1-Q7 | Link Khala shared packages | Yes, "shared with Khala" |
| R1-Q8 | Source links per component | Package or docs page, not source paths (paths move) |
| R1-§3 | Layout, entry design and page copy of the directory page | Kevin designs; approve the first generated page before C10-T04 |

### DESIGN-R2 — event bus

| ID | Question | Rec |
|---|---|---|
| R2-§1 | Confirm no change in C1–C4; topic names unchanged | Confirm |
| KQ-R2-1 (S1) | Export retention default; configurable | 7 days or 50,000 events, smaller wins; configurable — covers a weekend offline, bounds disk |
| KQ-R2-2 (S2) | Ship `aiur events tail` | Yes, read-only — the only way to inspect the feed without a client |
| R2-S3 | `aiur status` export-feed line | Only when the feed is enabled |
| R2-S4 | Cursor older than retention | `reset` + snapshot; no stale replay |
| KQ-R2-3 | External feed free text or identifiers only | Identifiers only (same rule as Executor wake records) |

### DESIGN-R3 — optional Tailscale

| ID | Question | Rec |
|---|---|---|
| R3-§1 | Confirm no change and no new config key | Confirm |
| R3-Q1 | Plain HTTP beyond a tailnet: warning only, or a Bucket 2 TLS feature | Warning only (phone HTTPS is P2) |
| R3-Q2 | Banner on the historical `docs/voice-mode/spec.md` | Leave historical specs untouched — they are dated records |
| R3-§3 | Approve the two docs paragraphs | Approve |

### DESIGN-R4 — `hooks.aiur.dev` relay

| ID | Question | Rec |
|---|---|---|
| R4-§1 | Confirm no change; no relay configuration UX; optional guided-setup request | Confirm; no request |
| R4-Q1 | Keep `hooks.aiur.dev` purely for GitHub webhooks | Yes |
| R4-Q2 | Seen: self-hosters cannot hold APNs/FCM credentials | "Seen"; the answer is DESIGN-N4 D-8 (P1) |
| R4-§3 | Approve the Cloudflare tunnel boundary paragraph | Approve |

### DESIGN-R5 — ElevenLabs speech-to-text package

| ID | Question | Rec |
|---|---|---|
| R5-§1 | Confirm no change for configured key, missing key, key setup | Confirm |
| R5-§2 copy | Approve "not installed" copy (dashboard, deck, credits row) | Approve as proposed |
| R5-§2 X9 | Hidden or disabled when not installed (every surface) | See X9: disabled with reason |
| R5-Q1 | Default npm install includes the voice package | Include — the key stays the opt-in |
| R5-Q2 | Delete the unwired sidecar TTS file | Delete — it would need a key in the sidecar |

### DESIGN-R6 — Stream Deck

| ID | Question | Rec |
|---|---|---|
| R6-§1 | Confirm deck, dictation, targeting, emulator, setup unchanged | Confirm |
| R6-Q1 | Hardware re-proof on Kevin's deck before C2 merges | Required, one manual pass — the deck is a daily surface |
| R6-Q2 | Deck grouping rule as E4's starting rule | Yes, start there — already proven on the deck |

### DESIGN-R7 — harness adapter

| ID | Question | Rec |
|---|---|---|
| R7-§1 | Confirm delivery paths, backends, Remote Control, skills, packaging unchanged | Confirm |
| R7-Q1 | One foreground manual run (Codex + Claude) enough for C4 | Yes — it is the AGENTS.md definition of manual testing |
| R7-Q2 | File the `aiur-claude` `turn/steer` bug now | File now — precondition of MP-E7-C4 |

## 3. Bucket 2 gates

### DESIGN-E1 — build queue

| ID | Question | Rec |
|---|---|---|
| OQ-1 | List position in the start order | critical path → priority → list position → age — keeps D3's first keys |
| OQ-2 | Prerequisite closed "not planned": fail or satisfy | Fail — matches the Build Order view |
| OQ-3 | Promote ready tickets carrying `agent:paused`/`parked`/`needs-triage`/`human:todo` | No; show "held by marker" — those labels are deliberate parks |
| OQ-4 | Marker label name and colour | `agent:queued`, neutral grey distinct from `agent:todo` |
| OQ-5 | Write "after #N" edges as GitHub dependencies | No for v1 — keeps local plans out of the shared graph |
| OQ-6 | Queue on by default | Yes — an empty queue makes no API calls |
| OQ-7 | aiur-build/aiur-run create waiting members with the marker; adoption withdraws `agent:todo` | Yes and yes — otherwise `agent:todo` means "maybe ready" |
| E1-CLI | Approve or rename the `aiur queue` verbs and their output | Approve the D7 draft verbs |
| E1-PLACE | Read-only view: new `/queue` page or panel on `/build-orders` | Panel on `/build-orders` — same progress figure, no new nav item |
| E1-COPY | Attention copy and Executor instruction for 7 alerts | Approve the §5 draft table — each line names ticket, cause, one next action |

### DESIGN-E2 — Command request, response, escalation

| ID | Question | Rec |
|---|---|---|
| E2-6.1 | Escalation timeouts | Ack 5 min, answer 15 min; half for blocking high-urgency |
| E2-6.2 (X10) | Visibility of "With Executor" Commands; what counts | See X10 |
| E2-6.3 | Wording of routing chips and escalation causes | §4.1 draft chips; causes as short sentences |
| E2-6.4 | Show all 4 options for native questions | Yes — hiding one would change the agent's question |
| E2-6.5 (X6) | Multi-question layout (dashboard and phone) | See X6 |
| E2-6.6 | Executor-originated Commands: one inbox with filter, or separate section | One inbox, "From Executor" filter |
| E2-6.7 | Keep "Defer to Executor" only for `supervisor_*` authority | Yes |
| E2-6.8 | Unit row copy while a native question holds the agent | "Waiting for your answer" |
| E2-6.9 (P8) | Backend-only tickets before approval | See P8 |
| E2-6.10 | Enable Codex `default_mode_request_user_input` in production | Keep off until both spikes show the turn holds without timeout, then enable |
| E2-4.1a | Missing short label fallback | First words of the question — the kind alone does not tell Commands apart |
| E2-4.2b | Multi-select presentation | Checkboxes with a single Submit |

### DESIGN-E3 — Executor conversation

| ID | Question | Rec |
|---|---|---|
| E3-1 (= OQ-E3-1) | Claude first, Codex later, or both | Claude first — Codex reading waits on RQ-E3-1/2 |
| E3-3 (= OQ-E3-4) | Default content | Messages plus collapsed tool calls; reasoning hidden (same as E4-3) |
| E3-4 (= OQ-E3-2) | Executor transcript readable on paired devices by default | Yes — D19 already grants full access |
| E3-5 (= OQ-E3-5) | Takeover from dashboard or CLI only | CLI only in v1 — rare and destructive |
| E3-6 (= OQ-E3-6) | aiur-run emits `executor.progress` jump points | Yes — progress tables are natural chapter marks |
| E3-7 | Blockers scope | Include fleet-level blockers — they are what stops the Executor |
| E3-8 | Terminology | Confirm — already the term in skills and CLI |
| E3-9 (CR-E3-8) | `executor-attach` installs Claude hooks automatically | Install automatically — `settings.local.json` is per-user and gitignored; blocks MP-E3-C1-T04 |

E3 decision 2 (Executor default mode) is X1, owned by DESIGN-E7.

### DESIGN-E4 — conversation view and event navigation

| ID | Question | Rec |
|---|---|---|
| E4-1 | Layout | Starting point: one chronology with an event rail (Kevin designs) |
| E4-2 | Default jump-point kinds | On: progress, push, PR opened/merged, Command; off: CI, comments |
| E4-3 | Reasoning and raw tool output | Collapsed |
| E4-4 | Mask likely secrets at display time | Mask, reveal for loopback sessions; devices always redacted (security M5) |
| E4-5 | Keep every transcript forever | Confirm — about 2 GB per agent-year at the p50 upper bound |
| E4-6 | Keep the drawer | Keep, with a "Full conversation" link |
| E4-7 | Show "approximate position" | Show a subtle marker |
| E4-8 | Inline Command card placement (review T-8) | At its anchor with a pinned chip; no anchor → pinned "position unknown" |

### DESIGN-E5 — dashboard voice input

| ID | Question | Rec |
|---|---|---|
| E5-OQ1 | Two buttons, or one mic opening a chooser | One mic with a chooser — same shape on phone and watch |
| E5-OQ2 | Existing auto-send voice chat | Remove when E6 ships; until then keep under its label |
| E5-OQ3 | Dictating a Command answer | Auto-select Custom; append |
| E5-OQ4 | No key (not configured) | Disabled with reason and setup link (not-installed half is X9) |
| E5-OQ5 | Keyboard / hold-to-talk | Toggle stays; `Escape` cancels; no hold-to-talk |
| E5-OQ6 | Device picker inline or popover | Popover — the composer has room for one mic control |
| E5-OQ7 | Daily STT-minute cap for dictation | None in v1; revisit above 30 min/day of watch relay use |
| E5-CONF | Dictation keeps review-then-Send | Confirm |

### DESIGN-E6 — conversational voice assistant

| ID | Question | Rec |
|---|---|---|
| E6-OQ1 | How a draft becomes an instruction | On-screen Confirm only; speech may only focus the button (security m4) |
| E6-OQ2 | Confirm before consulting the agent | First consult per session only |
| E6-OQ3 | Where roles live; which ship | `.aiur/voice/roles/*.md`; ticket and project discussion |
| E6-OQ4 | Voice and name | Reuse `elevenlabs.voice_id`; no persona name |
| E6-OQ5 | May the user delete a transcript | Whole session, by user, with confirmation |
| E6-OQ6 | Cost caps | 20 min session, 120 s idle, **60 min/day default** (feasibility M8) |
| E6-OQ7 | Cloud disclosure; default LLM | Claude Haiku 4.5 — adds no new data processor beyond ElevenLabs |
| E6-OQ8 | One target per session | Yes |
| E6-OQ9 (P5) | Paid spike | See P5 |
| E6-OQ10 | Label for `origin: voice_assistant` entries | "via voice assistant" tag |
| E6-OQ11 | Show `via: voice_assistant` outside the Command timeline | Timeline only |

### DESIGN-E7 — listener modes

| ID | Question | Rec |
|---|---|---|
| E7-D1 (P6) | Package home | See P6 |
| E7-D2 | Headless Claude `steer` | Offer, labelled "interrupts current turn" — today's behaviour |
| E7-D3 | Who may change a worker's mode | Human and Executor, audited |
| E7-D4 | After async → sync/steer, unread messages | Notice only — a batch would land as one confusing turn |
| E7-D5 (P7) | Mode lifetime | See P7 |
| E7-D6 (X2) | Default change to `sync` | See X2 |
| E7-D7 | Global default-mode config key | Per-agent only for v1 — a key can be added later |
| E7-D8 (X1) | Executor default mode | See X1 |
| OWNER-NPM | npm trusted publisher for the Khala package | Set up trusted publishing — no long-lived token; blocks MP-E7-C1-T03 |
| E7-UI-1 | Where the selector lives | Drawer header + read-only badge on the unit row |
| E7-UI-5 | CLI verb | `aiur listen-mode <ticket> [steer\|sync\|async]`; `aiur message` prints the mode |
| E7-UI-6 | TUI shows mode / key changes it | Show it; no key in v1 |
| E7-UI-7 | Executor composer selector | Same selector, default from E7-D8 |

## 4. Bucket 3 gates

### DESIGN-N1 — app shape and shell

| ID | Question | Rec |
|---|---|---|
| D-N1-1 | Approve the 18-row native/WebView split | Approve as written |
| D-N1-2 (P3) | Distribution | See P3 |
| D-N1-3 | Minimum OS | iOS 17+, Android 10+ |
| D-N1-4 | App name and icon | "aiur", existing logo |
| D-N1-5 | Native header over WebView pages | Back, instance name, freshness pill, Executor-chat button |
| D-N1-7 | Demo mode for private distribution | Only if public |
| D-N1-8 (P4) | Validation devices | See P4 |
| OWNER-AUTH-N1-PROTO (P9) | Expo prototype | See P9 |
| N1-FRAME | Tab bar or stack | Stack rooted at the instance list — a tab bar invites a combined inbox |

D-N1-6 (HTTP-degraded mode) is X8, owned by DESIGN-N2.

### DESIGN-N2 — setup, pairing, revocation

| ID | Question | Rec |
|---|---|---|
| Q1 (= OQ-N2-1) | Machine settings in `~/.aiur/machine` | Yes — `~/.aiur/config` is the fallback workflow config |
| Q2 (= OQ-N2-2) | Auto-start the gateway | Yes, best effort |
| Q3 (= OQ-N2-3) | Device idle expiry | None — tokens already expire every 15 min |
| Q4 (= OQ-N2-4) | Lost only-device needs machine access to revoke | Accept and document `aiur mobile revoke` over SSH, with N6 D-2 unlock |
| Q5 (= OQ-N2-5) | Where the QR appears; hiding rules | Terminal + settings page; hidden from device sessions, read-only dashboards, non-loopback plain HTTP |
| Q6 (X3) | Stopped-instance retention | See X3 |
| Q7 | Default device label; editable on the machine | OS device name, editable on both sides |
| Q8 (RC-42, security B1) | Same-user agents can pair themselves: accept, or (a) separate OS user, (b) keyring keys, (c) agent deny rules | Ship (c) + integrity alert by default, show the residual risk, document (a); do not block `mobile.enabled` on (a) |
| §transport-cert (P2) | T-A or T-B | See P2 |
| §transport-HTTP (X8) | HTTP-degraded mode | See X8 |

### DESIGN-N3 — meta-dashboard

| ID | Question | Rec |
|---|---|---|
| N3-Q1 | Group by machine or one urgency-sorted list | One list by urgency, machine label per row |
| N3-Q2 | Field order; what drops first | Repo, Commands, Executor, agents, build %, background; drop background then build % |
| N3-Q3 | Build-order figure with several open | Most recently active, "+N more" |
| N3-Q6 | Wording for unavailable / stale / unreachable | Reuse the dashboard's "unavailable" and CLI freshness terms |

N3 Q4 is X3 (DESIGN-N2 Q6); N3 Q5 is X4 (DESIGN-N5 D-9); the count follows X10.

### DESIGN-N4 — notification presentation

| ID | Question | Rec |
|---|---|---|
| D-1 | Fallback copy | Title `aiur`, body `New notification` |
| D-2 | Per-kind copy patterns | As drafted in the gate |
| D-3 | Blocking Commands Time Sensitive | Yes — needs the capability and an NSE device check (feasibility m7) |
| D-4 (= OQ-N4-3) | NSE filtering entitlement | Apply; passive line as fallback |
| D-5 | Grouping | Per instance |
| D-6 | One-time "When Unlocked" tip | Yes, once, in setup (optional under D-10 (a)) |
| D-7 (X7) | Option labels in the payload | See X7 |
| D-8 (P1, = OQ-N4-1) | Publisher and default relay operator | See P1 |
| D-9 (= OQ-N4-2) | Encrypted response mailbox | Defer — keeps the relay stateless |
| D-10 (security m9) | Decrypted text on lock screen and watch | Hide body while locked |

### DESIGN-N5 — notification preferences

| ID | Question | Rec |
|---|---|---|
| D-1 (= OQ-N5-1) | Mute one instance's blockers | Yes, with a "muted" badge; amends D18 if accepted |
| D-2 (= OQ-N5-2) | Reminder for an unanswered blocker (delivery-reliability risk) | One reminder at 30 min, replacing the first (feasibility M3) |
| D-3 | Commit-push and comment notifications | Not in v1 |
| D-4 (= OQ-N5-4) | Non-blocking "needs you" default | On by default |
| D-5 | Re-notify a reopened build order | Yes |
| D-6 | Quiet hours or OS Focus | OS Focus only |
| D-7 | Wording | Reuse dashboard terms and D18 phrasing |
| D-8 (= OQ-N5-7) | Executor-created queue milestones | Follow the build-order setting |
| D-9 (X4) | App icon badge | See X4 |

### DESIGN-N6 — phone and watch Command response

| ID | Question | Rec |
|---|---|---|
| D-1 (= OQ-N6-1) | Queue offline answers | No on the phone; the watch `transferUserInfo` retry is the named exception |
| D-2 (= OQ-N6-2) | Unlock before submitting | Yes, for writes (feasibility m9) — a lost phone stays authorized |
| D-4 | Watch: "Answer on phone" for multi-question Commands | Yes |
| D-5 | Option details on the watch | No |

N6 D-3 is X5 (DESIGN-N7).

### DESIGN-N7 — watch

| ID | Question | Rec |
|---|---|---|
| D-N7-1 | Phone-dependent watch apps only | Yes |
| D-N7-2 | Default Dictate path | System recognizer, with disclosure |
| D-N7-3 / D-N7-4 (X5) | Converse latency; hand-off | See X5 |
| D-N7-5 | Complication / Tile | Yes, count + oldest age |
| D-N7-6 | Apple Watch and Wear OS together | Apple Watch first unless P4 lists a Wear OS device |
| D-N7-7 | Short labels | Reuse dashboard terms, abbreviated |
| D-N7-8 | Card context depth | Summary + 2 lines + marker |
| D-N7-10 (feasibility M5) | If DV-W1 fails | Accept the fallback; its tap opens the card through the phone |

D-N7-9 is X7 (DESIGN-N4 D-7).

## 5. Not owner questions (excluded from the count)

Research questions (RQ-*), coordinator decisions (RC-*, CQ-*), and "MP-E1 owner review" in
MP-R1-C8-T09 (a code-owner review on a PR, not a product decision) are excluded. Copy and
layout approval of each gate's states table is part of that gate's approval, not a separate
question.

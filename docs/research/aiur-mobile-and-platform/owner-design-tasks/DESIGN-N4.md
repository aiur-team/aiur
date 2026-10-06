---
design_task: DESIGN-N4
feature_id: MP-N4
owner: Kevin (operator)
status: open — not approved
blocks: [MP-N1-C6-T01, MP-N1-C10-T01, MP-N2-C5-T06, MP-N4-C1-T01, MP-N4-C1-T02, MP-N4-C1-T03, MP-N4-C1-T04, MP-N4-C2-T01, MP-N4-C2-T02, MP-N4-C2-T03, MP-N4-C2-T04, MP-N4-C2-T05, MP-N4-C2-T06, MP-N4-C2-T07, MP-N4-C3-T00, MP-N4-C3-T01, MP-N4-C3-T02, MP-N4-C3-T03, MP-N4-C3-T04, MP-N4-C3-T05, MP-N4-C3-T06, MP-N4-C3-T07, MP-N4-C4-T01, MP-N4-C4-T02, MP-N4-C4-T03, MP-N4-C4-T04, MP-N4-C4-T05, MP-N4-C5-T01, MP-N4-C5-T02, MP-N4-C5-T03, MP-N4-C5-T04, MP-N4-C5-T05, MP-N4-C6-T01, MP-N4-C6-T02, MP-N4-C6-T03, MP-N4-C7-T01, MP-N4-C7-T02, MP-N5-C4-T02, MP-N5-C5-T01, MP-N6-C6-T02, MP-N7-C2-T04, MP-N7-C3-T04]
blocks_note: "Phase D: the list is the tickets whose blocked_by names DESIGN-N4 (waived entries excluded). Earlier wording: MP-N4-C4, MP-N4-C5, MP-N4-C6 and the setup copy in MP-N4-C3 (see ../bucket-3-mobile-watch/MP-N4/chunks.md)"
shared_with: DESIGN-N5 (preferences), DESIGN-N6 (what a tap opens), DESIGN-N7 (watch looks), DESIGN-N2 (setup and pairing), DESIGN-E2 §4.1 (short label)
base_main_sha: 45a290e3
date: 2026-10-06
---

# DESIGN-N4 — Kevin: design and approve notification presentation

Deliver the notification designs, states, copy and an explicit approval.
**MP-N4 user-visible implementation stays blocked until this task is approved.** The
crypto library, relay service and daemon client (MP-N4-C1–C3) may proceed.

## 1. Fixed by research (not up for redesign)

- The clear text Apple/Google can see is **one uniform string for every notification**;
  it shows whenever the device cannot decrypt (restarted and not yet unlocked, extension
  timeout). It cannot name a machine, repo, ticket, kind or count.
- The decrypted line is: title = Command short label (≤ 40 chars, DESIGN-E2 §4.1),
  subtitle = instance label · requester (≤ 60), optional body (≤ 160).
- No recording or answering inside the banner in v1; tap opens the Command (DESIGN-N6).
- The clear fallback is pinned per app at the relay (security review m1), so a relay
  cannot show other clear text through aiur's sends.
- Sources: [MP-N4 plan](../bucket-3-mobile-watch/MP-N4/plan.md),
  [platform evidence](../bucket-3-mobile-watch/MP-N4/platform-evidence.md).

## 2. Surfaces

| Surface | Design |
| --- | --- |
| iOS lock screen / banner / Notification Centre | title/subtitle/body layout per kind; grouping (one group per instance proposed) |
| Android shade and heads-up | channels (Commands, Progress, Other), icon, grouping per instance |
| Apple Watch short look / long look | with DESIGN-N7 |
| Wear OS bridged notification | with DESIGN-N7 |
| Fallback (undecryptable) | copy only |
| Retraction (resolved elsewhere) | silent removal vs quiet "Answered on <surface>" line |
| Digest | "3 updates on aiur: 2 Commands need you, build 50 %" layout |
| Setup: notifications off / relay not configured / permission denied / force-stopped (Android) | in-app banners and the machine-side `aiur` status line |

## 3. Decisions that need Kevin

- **D-1 Fallback copy.** Proposal: title `aiur`, body `New notification`.
- **D-2 Per-kind copy patterns.** Proposals: Command `Migration decision` /
  `aiur · #2731 · blocking`; Executor Command `Release go/no-go` / `aiur · Executor`;
  progress `Build 50 %` / `aiur · <build order title>`; complete `Build complete`;
  PR merged `PR merged` / `aiur · #2731`.
- **D-3 Interruption level.** Should blocking Commands be Time Sensitive (break through
  Focus; user can turn it off) and non-blocking Active? Proposal: **yes for blocking**,
  because a blocker that waits behind Focus stalls an agent. If accepted, the app needs the
  Time Sensitive Notifications capability and a device check that a level set in the NSE
  is honoured (Phase D, feasibility m7; MP-N1-C6-T01, V-I5).
- **D-4 Retraction presentation.** Silent removal needs Apple's filtering entitlement
  (applied for, not guaranteed). Without it: a quiet passive line. Choose: apply for the
  entitlement (proposal) and accept the passive line as fallback.
- **D-5 Grouping.** One thread per instance (proposal) or per machine.
- **D-6 Lock-screen privacy hint.** Show an in-app tip recommending "Show previews: When
  Unlocked"? Proposal: yes, once, in setup.
- **D-7 Command option labels in the payload** (Phase D). **This gate owns the question;**
  DESIGN-N7 D-N7-9 links here and does not ask it again. The conditional Apple Watch
  long-look buttons (MP-N7-C2-T06) need up to three option ids and labels inside the
  encrypted payload, and those labels then show on a locked watch face.
  Options: (a) allow up to 3 labels, within the payload budget; (b) no labels — tapping
  the notification opens the Command card. **Recommendation: (b)**, because it keeps the
  payload minimal and keeps option text off the lock screen; MP-N7-C2-T06 is then not built.
  [ ] (a) allow  [ ] (b) no, the card opens
- **D-8 Store-app publisher and default push-relay operator (OQ-N4-1; Phase D, main mobile
  blocker).** Whoever sends a push to a store app's bundle id must hold that publisher's
  APNs key and Firebase project credentials (MP-N4 plan E-A6, E-F6), so this cannot be
  "each user's machine". Options:
  - (a) **aiur-team organisation accounts** (Apple Developer Program as an organisation,
    one Firebase project) and an **aiur-team hosted relay**: the C2-T05 image as a small
    container, one sandbox and one production instance (MP-N4-C2-T06). Self-hosters may
    still run their own relay with self-built apps.
  - (b) **Self-built apps only.** No store or TestFlight build is published; each user
    builds the app with their own Apple and Firebase accounts and runs the reference relay.
    No hosted service exists.
  - (c) **Kevin's personal accounts** and a personal host.

  **Recommendation: (a).** Any TestFlight or store build needs exactly one publisher, and an
  organisation identity does not tie the product's signing and push credentials to one
  person. The relay is a forwarder that stores nothing (§1), so operating it is small.
  Cost: the annual Apple Developer Program fee, plus hosting that RQ-N4-7 must measure
  before C2-T06 ships. Holds MP-N4-C2-T06, C2-T07, C7-T02 and MP-N1 distribution.
  [ ] (a)  [ ] (b)  [ ] (c)  — account owner, host and budget: ______
- **D-9 Encrypted response mailbox for off-network answers (OQ-N4-2).** A later chunk could
  let a phone that cannot reach the machine leave a sealed answer on the relay for the
  daemon to collect. That changes the relay from a forwarder into a store of user answers
  and adds a polling loop to every daemon (MP-N4 plan §9). Options: (a) not in v1 —
  off-network, the phone shows the notification and "Can't reach <machine>" (DESIGN-N6),
  and the answer waits until the phone can reach the machine; (b) plan the mailbox as a
  v1.x chunk now. **Recommendation: (a), defer**, because it keeps the relay stateless,
  which is the basis of the §1 privacy claims. [ ] (a) defer  [ ] (b) plan it
- **D-10 Decrypted text on the lock screen and the watch** (Phase D, security review m9).
  Decrypted summaries ("Pick a schema migration strategy before #2731…") appear on a locked
  phone and on the watch. Options: (a) **hide the body while locked** — iOS
  `hiddenPreviewsBodyPlaceholder`, Android `VISIBILITY_PRIVATE` with a public version that
  uses the D-1 fallback text; (b) follow the OS preview setting only. Recommended: **(a)**,
  because Command text is often repository-internal and a locked phone is readable by
  anyone nearby. Under (a) the D-6 in-app tip becomes optional. Implemented by
  MP-N4-C4-T03 and C5-T03; device row V-LS1.

## 4. States to design

Delivered and decrypted · fallback (undecryptable) · digest · retracted/resolved ·
expired (not shown) · notifications disabled by OS · relay not configured ·
relay degraded (shown in app settings and `aiur status`) · device unpaired · app
force-stopped (Android) · watch mirrored vs direct · **phone notifications broken** (push
keys lost on the device; re-pair needed — machine side in `aiur push status` /
`aiur mobile status`, MP-N4-C3-T07 state `:keys_lost`; phone side the fallback
notification opens "Open aiur to re-pair"; feasibility M6).

## 5. Acceptance conditions

- Every surface in §2 and state in §4 has a design for iOS and Android.
- Every decision in §3 (D-1…D-10, including D-8 publisher and relay operator, D-9
  mailbox and D-10 lock screen) recorded with Kevin's answers.
- Copy fits the length caps above at the default system text size and the largest
  accessibility size.
- Kevin explicitly approves. Nobody else marks this task complete.

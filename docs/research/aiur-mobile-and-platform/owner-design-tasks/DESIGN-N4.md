---
design_task: DESIGN-N4
feature_id: MP-N4
owner: Kevin (operator)
status: open — not approved
blocks: MP-N4-C4, MP-N4-C5, MP-N4-C6 and the setup copy in MP-N4-C3 (see ../bucket-3-mobile-watch/MP-N4/chunks.md)
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
  Focus; user can turn it off) and non-blocking Active? Proposal: yes for blocking.
- **D-4 Retraction presentation.** Silent removal needs Apple's filtering entitlement
  (applied for, not guaranteed). Without it: a quiet passive line. Choose: apply for the
  entitlement (proposal) and accept the passive line as fallback.
- **D-5 Grouping.** One thread per instance (proposal) or per machine.
- **D-6 Lock-screen privacy hint.** Show an in-app tip recommending "Show previews: When
  Unlocked"? Proposal: yes, once, in setup.

## 4. States to design

Delivered and decrypted · fallback (undecryptable) · digest · retracted/resolved ·
expired (not shown) · notifications disabled by OS · relay not configured ·
relay degraded (shown in app settings and `aiur status`) · device unpaired · app
force-stopped (Android) · watch mirrored vs direct.

## 5. Acceptance conditions

- Every surface in §2 and state in §4 has a design for iOS and Android.
- D-1…D-6 recorded with Kevin's answers.
- Copy fits the length caps above at the default system text size and the largest
  accessibility size.
- Kevin explicitly approves. Nobody else marks this task complete.

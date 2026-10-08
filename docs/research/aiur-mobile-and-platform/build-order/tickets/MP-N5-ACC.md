# MP-N5-ACC — MP-N5 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-N5-C1-T04, MP-N5-C1-T05, MP-N5-C3-T02, MP-N5-C3-T03, MP-N5-C4-T02, MP-N5-C4-T03, MP-N5-C5-T01

## Outcome

The Executor proves MP-N5 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-N5/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (17)

- MP-N5-C1-T01 — Notification preference schema v1 and machine-store file
- MP-N5-C1-T02 — Effective preference resolution per (device, instance) with capability masking
- MP-N5-C1-T03 — Settings API — gateway GET/PATCH /v1/notification-settings and instance notification-options
- MP-N5-C1-T04 — Seed defaults at pairing and baseline progress trackers silently per instance
- MP-N5-C1-T05 — Per-instance mute of blocker Commands on a device (if DESIGN-N5 D-1 = yes)
- MP-N5-C2-T00 — Post-refactor path refresh for the notification policy
- MP-N5-C2-T01 — Policy process — event Source adapter (export feed or live), dedup ledger, boot and gap reconciliation
- MP-N5-C2-T02 — Command rules — needs_you on human_needed, retraction on terminal states, no re-ask pushes
- MP-N5-C2-T03 — Progress rules — per-device 10/25/50 % thresholds from the E1 read API and progress signal
- MP-N5-C2-T04 — Opt-in rules — PR merged, agent retry exhausted, CI failed
- MP-N5-C3-T01 — Coalescing window and digest intents per (device, instance)
- MP-N5-C3-T02 — Hourly cap for non-Command notifications per (device, instance)
- MP-N5-C3-T03 — Send-time staleness hook for the push outbox (no burst after reconnect)
- MP-N5-C4-T01 — Phone notification settings — machine defaults, per-instance overrides, unavailable reasons
- MP-N5-C4-T02 — OS notification permission state on the settings screen and deep link to OS settings
- MP-N5-C4-T03 — Settings offline, stale, save-conflict and unpaired states
- MP-N5-C5-T01 — Notifications guide page — defaults, options, limits, what Apple/Google/relay see

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.

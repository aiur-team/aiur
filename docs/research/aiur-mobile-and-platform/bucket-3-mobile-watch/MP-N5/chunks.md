---
feature_id: MP-N5
base_main_sha: 45a290e3
date: 2026-10-06
---

# MP-N5 chunks

**Phase C (2026-10-06):** full ticket docs in [tickets/](tickets/README.md). Changes:
C1 adds T05 (blocker mute, blocked on DESIGN-N5 D-1); C2 is renumbered (T01 Source +
ledger + reconciliation foundation; T02 Commands; T03 progress per RC-10 without the
CatalogStore fallback; T04 opt-ins); settings live in the machine store (RC-03).

| Chunk | Outcome | Depends on | Design gate |
| --- | --- | --- | --- |
| MP-N5-C1 | Preference model, store and capability-aware settings API | MP-N2 device registry + device auth (A-N2-1, A-N2-4), MP-R1 capability API | API: none; copy of reasons: blocked-by-design |
| MP-N5-C2 | Policy engine: Commands, progress tracker, opt-ins, dedup ledger, cursor | C1, MP-N4-C3, MP-E2 `human_needed` + terminal slugs, MP-E1 milestone producer (E1 chunk C7) or fallback, MP-R2 durable consumer | none (no UI) |
| MP-N5-C3 | Noise control and staleness: coalescing, digest, caps, send-time staleness | C2, MP-N4-C3 outbox | digest copy: blocked-by-design |
| MP-N5-C4 | Settings screen in the phone app (and watch if MP-N7 adopts direct push) | C1, MP-N1 shell | blocked-by-design (DESIGN-N5) |
| MP-N5-C5 | Docs: configuration reference + guide page | C1–C4 | none |

---

## MP-N5-C1 — Preferences store and settings API

Tickets:
- MP-N5-C1-T01 Preference schema v1 (plan §4) with validation, versioning and defaults
  from D18; stored beside `devices.json` in the MP-N2 machine store, written only by the
  gateway (write temp, fsync, rename), read by instances.
- MP-N5-C1-T02 Effective-preference resolution `(device, instance)` with overrides.
- MP-N5-C1-T03 Settings API: gateway `GET/PATCH /v1/notification-settings` with
  `expected_version`; instance `GET /api/v1/device/notification-options` returning each
  option's availability from that instance's capabilities (`build_orders.progress`,
  `build_queue`, `commands.answer`, event sources).
- MP-N5-C1-T04 Seed and baseline: on pairing (MP-N2 hook) create defaults and baseline
  progress trackers silently.
- MP-N5-C1-T05 Per-instance blocker mute (blocked on DESIGN-N5 D-1 / OQ-N5-1).

Tests: availability matrix fixtures (build orders absent / partial progress / present);
unknown-path mutation check (replace `unavailable` with `off` → test fails); concurrent
writes from two devices through the gateway (`expected_version` conflict); instance
readers see the new file after the gateway's rename.

## MP-N5-C2 — Policy engine

Tickets:
- MP-N5-C2-T00 Plan refresh: map event/CatalogStore paths to post-refactor packages.
- MP-N5-C2-T01 Policy process: Source adapter (export DurableConsumer or live Exchange,
  RC-09), dedup ledger, boot/gap reconciliation.
- MP-N5-C2-T02 Command rules (plan §5.1) over the MP-E2 routing contract; re-ask
  exclusion; retraction intents.
- MP-N5-C2-T03 Progress rules (plan §5.2, RC-10): per-device 10/25/50 % from
  `Aiur.BuildProgress.facts/1` (owned by the `build-orders` component, RC-40) and the progress-changed signal; persisted trackers.
- MP-N5-C2-T04 Opt-in sources (`pr.merged`, `agent.retry_exhausted`, `ci.failed`).

Tests: table-driven progress sequences (AC-N5-3/4); escalation sequences (AC-N5-1);
re-ask flood (AC-N5-2); kill-and-restart (AC-N5-5); webhook+poller double observation of
one merge (AC-N5-9).

## MP-N5-C3 — Noise control and staleness

Tickets:
- MP-N5-C3-T01 Coalescing window and digest intent builder (counts per kind; destination
  = instance).
- MP-N5-C3-T02 Hourly cap for non-Command kinds.
- MP-N5-C3-T03 Send-time staleness checks in the outbox (plan §5.6) — implemented as a
  hook MP-N4-C3 calls before sealing.

Tests: AC-N5-6, AC-N5-8; clock-controlled tests (no sleeps).

## MP-N5-C4 — Settings screen

Tickets:
- MP-N5-C4-T01 Machine defaults + per-instance overrides UI with unavailable reasons
  (blocked-by-design).
- MP-N5-C4-T02 OS permission state surfacing (iOS authorization, Android
  `POST_NOTIFICATIONS`) and deep link to OS settings.
- MP-N5-C4-T03 Offline/stale states per DESIGN-N5.

Tests: UI tests per state; device run folded into MP-N4-C7 (V-PR1..3).

## MP-N5-C5 — Docs

- MP-N5-C5-T01 `website/docs-app/reference/configuration.md` (any machine-level keys),
  `website/docs-app/guide/` notifications page (defaults, what each option means, what
  Apple/Google see — linking MP-N4 evidence), sidebar entry.

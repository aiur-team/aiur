# MP-N4-ACC — MP-N4 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-N4-C2-T07, MP-N4-C3-T05, MP-N4-C3-T06, MP-N4-C3-T07, MP-N4-C4-T05, MP-N4-C5-T05, MP-N4-C6-T03, MP-N4-C7-T02

## Outcome

The Executor proves MP-N4 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-N4/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (34)

- MP-N4-C1-T01 — Pin the push crypto primitives to OTP 28 and add a runtime support guard
- MP-N4-C1-T02 — HPKE base-mode seal and open on the daemon, proven by RFC 9180 vectors
- MP-N4-C1-T03 — ProtectedPayload encoder, size budget, inner frame and detached Ed25519 signature
- MP-N4-C1-T04 — nid and collapse_token derivation plus the cross-platform golden vector file
- MP-N4-C2-T01 — Relay service skeleton — handle registry, send endpoint, idempotency, storage
- MP-N4-C2-T02 — Relay APNs adapter — token auth, HTTP/2, headers, error mapping
- MP-N4-C2-T03 — Relay FCM HTTP v1 adapter — data-only messages, priority/ttl/collapse, error mapping
- MP-N4-C2-T04 — Relay abuse controls — per-handle rate limit, size checks, log retention
- MP-N4-C2-T05 — Relay packaging — container image, CI workflow, operator guide page
- MP-N4-C2-T06 — Default relay deployment for store-distributed apps (publisher credentials, host, URL)
- MP-N4-C2-T07 — (Optional) Cloudflare Workers deployment of the relay
- MP-N4-C3-T00 — Post-refactor path refresh for the daemon push-relay component
- MP-N4-C3-T01 — Machine-level push: settings in ~/.aiur/machine with docs
- MP-N4-C3-T02 — Durable push outbox — persist-before-send, idempotent per (intent, device), restart resume
- MP-N4-C3-T03 — Fan-out and relay client — read device registry, seal per device, send, map responses
- MP-N4-C3-T04 — Push component supervision and the push capability (available / degraded / unavailable)
- MP-N4-C3-T05 — Push deregistration hook for revoke and unpair-all; per-instance purge
- MP-N4-C3-T06 — Privacy guard tests — no summary or identifiers in daemon logs or relay requests
- MP-N4-C3-T07 — Machine-side push status line in aiur status / aiur mobile status and setup copy
- MP-N4-C4-T01 — iOS per-machine push keys and pinned machine keys in the shared keychain group
- MP-N4-C4-T02 — iOS payload acceptance pipeline — open, verify, expiry, seen-nid, stream supersession
- MP-N4-C4-T03 — iOS presentation mapping — title/subtitle/body, thread, category, interruption level
- MP-N4-C4-T04 — iOS retraction — remove delivered notifications listed in retracts
- MP-N4-C4-T05 — iOS push registration — APNs token, relay handle per machine, push_registration record
- MP-N4-C5-T01 — Android per-machine Tink HPKE keysets and pinned machine keys
- MP-N4-C5-T02 — Android acceptance pipeline in onMessageReceived — decrypt, verify, dedup, always post
- MP-N4-C5-T03 — Android channels, notification rendering, POST_NOTIFICATIONS flow and force-stop warning
- MP-N4-C5-T04 — Android retraction — cancel by nid tag and stream supersession
- MP-N4-C5-T05 — Android push registration — FCM token, relay handle per machine, token refresh
- MP-N4-C6-T01 — Apple Watch delivery — verify forwarded NSE content; direct-push fallback decision
- MP-N4-C6-T02 — Wear OS bridging — bridge tags and dismissal ids for app-posted notifications
- MP-N4-C6-T03 — Watch as a direct-push child device — registration record and daemon fan-out check
- MP-N4-C7-T01 — Device-validation harness — relay test tool, report template, capture scripts
- MP-N4-C7-T02 — Physical-device validation run and dated report (AC-N4-9)

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.

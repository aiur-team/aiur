# Capability baseline — Bucket 3 (mobile and watch, N1–N7)

Part of the [capability baseline](capability-baseline.md) (Phase A), split out to keep each file under 500 lines. Verified against `origin/main` @ `45a290e3`; the status legend (EXISTS, PARTIAL, NEW), method and summary table are in the [index](capability-baseline.md). Other parts: [bucket 1](capability-baseline-bucket-1.md), [bucket 2](capability-baseline-bucket-2.md), [bucket 3](capability-baseline-bucket-3.md).

---

## 3. Bucket 3 — Mobile and watch

### N1 — Cross-platform application architecture — NEW

**Not found:** react-native, expo, capacitor, flutter, `manifest.json`/webmanifest, service worker, `PushSubscription`. Searched everywhere except `node_modules`, `_build` and `docs/`.

**Existing web foundations a WebView could reuse:**
- Phoenix LiveView dashboard with a viewport meta tag and `apple-touch-icon` (`components/layouts.ex`).
- `src/priv/static/dashboard.css` has 39 `@media` rules (320–1024 px) plus `forced-colors`.
- Earlier mobile layout fixes: "Narrow the mobile nav into a centered pill" (`815052386`) and "Fix build-order Fit on mobile" (`869ceab1c`).

**Constraints a WebView would hit:**
- Basic Auth on every request.
- Same-origin and `X-Aiur-Request` checks on writes.
- Session-proof LiveView sockets.
- The `/voice` socket requires a CSRF token plus a session.

### N2 — Machine-level pairing and discovery — NEW (local seed only)

**What exists:**
- **Per-instance identity** (`packaging/npm/aiur-cli/libexec/aiur-engine.sh`):
  - `aiur_instance_key()` = the first 10 hex characters of sha256(realpath(project root)).
  - Node name `aiur-$USER[-KEY]@127.0.0.1`; tmux socket and session `aiur-$USER[-KEY]`.
- **Instance records:** `write_aiur_instance_record()` writes `${XDG_CONFIG_HOME:-~/.config}/aiur/instances/<node-slug>.instance`, mode 0600. Fields: `AIUR_RECORD_{NODE,INSTANCE_KEY,SESSION,SOCKET,AGENT_TMPFILE,SURFACE_MODE,WORKSPACE_ROOT_FILE,PROJECT_ROOT,PROJECT_ROOT_SOURCE,WRITTEN_AT}`.
  - **The record does not hold the dashboard host or port.**
  - The only reader is `resolve_control_identity_from_records()`, which handles control-command fallback by probing node liveness.
  - **[host]** Stale records persist. The owner's machine has 8 records dating back to 2026-07-28.
- **Lifecycle journal:** `<repo>.control-lifecycle.json` records starts and stops with pid and hostname.
- **Global machine config:**
  - `~/.aiur/config` is the fallback config.
  - `~/.aiur/.env` holds global secrets.
  - `~/.config/aiur/` holds distribution state (cookie, instances, `streamdeck.env`).

**Not found:**
- Pairing, QR, device tokens or keys.
- mDNS, Bonjour or avahi.
- A user-facing `aiur instances` / list command (`aiur status` is per instance).

### N3 — Meta-dashboard — NEW

- No multi-instance UI.
- Per-instance data a meta view could aggregate already exists:
  - Open and blocking Command counts (the `overview.ex` banner).
  - Active agents and capacity (`aiur status`, `/api/v1/state`).
  - Build-order progress (`RootSummary.progress`).
  - Executor roster state (`aiur executor-roster`).
- A second instance on the same fixed port disables only its own dashboard (configuration.md § server).

### N4 — Private, encrypted, rich background notifications — NEW

**Not found:** apns, fcm, firebase, web push, ntfy, pushover, notify-send, Slack/Discord/Twilio sinks.

**Existing notification-adjacent pieces:**
- **Local sounds:** `Aiur.Alerts`, config `alerts.{enabled,use_os_default_sounds,sound_dir,alerts_file}`.
- **Alert ledger:** `aiur alerts`.
- **Executor wakes:** consumed by an agent through `executor-wait`.
- **Daemon heartbeat:** `daemon_heartbeat.ex`, `monitoring.daemon_heartbeat_stale_ms`.
- **"Push" in code means git push:** `Aiur.Orchestrator.PushRouting`.

**Khala** (a separate product, `aiur-team/khala`):
- "Encrypted chat between agents" at `khala.aiur.team` (`website/docs-app/khala/quick-start.md`: "one end-to-end encrypted channel"). It also has a local-only channel mode.
- In this repo it is docs only; no integration code exists in `src/lib`.
- It is a possible prior-art or reuse candidate for an encrypted relay. That is unverified and needs research in the Khala repo.

### N5 — Notification preferences and progress updates — NEW

- No preference model.
- Signals that already exist:
  - `ticket.*.pr.merged` (Executor bindings and the feed).
  - Build-order `RootSummary.progress`.
  - `ticket.*.branch.push`.
  - Comments (`ticket.*.issue.commented`).

### N6 — Contextual command response — PARTIAL (non-mobile surfaces)

- **The Command payload already carries what the response view needs:** `question`, `context.short_summary` (a candidate for the short notification summary), `options` (suggested responses), `recommendation`, `consequence_of_delay`, `urgency`, `blocking`.
- **Answer paths:** the dashboard and the Stream Deck, with focus targeting and dictated `custom_response`.
- **Concurrency:** answers are idempotent and carry `expected_version`.
- **Gaps:** no deep-link scheme. The closest is the route `/commands/:decision_id`. No phone or watch client.

### N7 — Watch applications — NEW

- Not found. Searched watchos, wearos and watch. The only hit is the unrelated test fixture directory name `watchos` in `src/test/aiur/init_test.exs`.

---


# Stream Deck end-to-end proof evidence

Evidence directory for [#1358](https://github.com/aiur-team/aiur/issues/1358).
Each proof run gets its own subdirectory named by run ID (e.g. `2026-07-30-001/`).

## Run metadata (fill in before starting)

```text
aiur commit: <git rev-parse HEAD>
sidecar version: <N/A for emulator-only>
kernel: <uname -r>
browser/package commit: <SHA if different from aiur commit>
run started: <ISO-8601 timestamp>
run id: <YYYY-MM-DD-NNN>
```

## Checklist

Copy this checklist into a `run.md` inside your run directory and tick each item:

```
Emulator steps
- [ ] 01-start.png — /streamdeck loads with live agent keys
- [ ] 02-grid-units-parity.png — grid matches Units page (values logged in 02-values.txt)
- [ ] 02-grid-update.mp4 — grid updates after fleet change
- [ ] 03-paging.png — pager dots track dial D input
- [ ] 03-paging-inputs.mp4 — drag + wheel + keyboard each change page state
- [ ] 04-pause-dashboard-status.png — key → cmd mode; pause reflected in key + dashboard + aiurdev status
- [ ] 04-resume.png — resume returns live state
- [ ] 05-logs-bounds.mp4 — dial D scrolls events; dial A scrolls transcript; arrows correct at bounds
- [ ] 06-back-navigation.png — logs → cmd → grid in exact order; focused agent unchanged
- [ ] 07-touch-strip-dashboard.png — strip segments match dashboard header meters (values in 07-values.txt)
- [ ] 07-usage-update.mp4 — strip live-updates as usage changes

Package CI
- [ ] packages/streamdeck: npm ci && npm run lint && npm test && npm run build — all pass
- [ ] streamdeck browser spec: node scripts/run-browser-tests.mjs tests/streamdeck-emulator.browser.spec.mjs — pass

Browser coverage audit
- [ ] rg output reviewed; any remaining gaps filed as issues and linked from #1358

Hardware (conditional on #1342 go-decision)
- [ ] N/A — #1342 no-go  OR  steps 08–11 evidenced below
```

## Sanitization reminders

Do **not** commit or attach:
- credentials, tokens, API keys
- private issue text or raw provider responses
- agent transcripts or reasoning output
- serial numbers or machine-local paths
- PII of any kind

Blur or crop screenshots before attaching if they contain any of the above.

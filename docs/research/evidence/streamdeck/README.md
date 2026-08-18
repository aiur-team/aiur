# Stream Deck end-to-end proof evidence

Evidence directory for [#1358](https://github.com/aiur-team/aiur/issues/1358).
Each proof run gets its own subdirectory named by run ID (e.g. `2026-07-30-001/`).

## Two kinds of run

A **headless run** drives the real `/streamdeck` LiveView over the browser
fixture fleet and writes its own evidence directory:

```bash
cd src/browser
AIUR_STREAMDECK_PROOF_RUN=<run-id> npm run proof:streamdeck
```

It captures steps 1–7 with a recording of the whole session, and it fails
rather than screenshotting a broken surface. It cannot produce the two
confirmations that need a running Aiur daemon — `aiurdev status` for step 4,
and the dashboard header meters as a numeric cross-check for step 7 — so each
run's `run.md` names them as open.

A **live run** is the Executor-root procedure in
`docs/research/streamdeck-end-to-end-proof.md`, driven through
`scripts/aiurdev --test`. It is the only run that can close those two items, and
the only one that can evidence hardware steps 8–11. Agent workspaces must not
attempt it.

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
Emulator steps — a headless run writes all of these itself
- [ ] 01-start.png — /streamdeck loads with live agent keys
- [ ] 02-grid.png + 02-grid.txt — opening grid, bucketed and slotted
- [ ] 02-grid-after-change.png + 02-units.png + 02-grid-units-parity.txt — membership
      and column-major slot order match Units after a live fleet change
- [ ] 03-paging.png — pager dots track dial D; wheel and keyboard both reach the server
- [ ] 04-pause-cmd.png + 04-pause-grid.png + 04-pause.txt — key → cmd mode; the pause
      re-buckets the agent and flips its control action
- [ ] 04-resume.png — resume returns live state
- [ ] 05-logs-live-end.png + 05-logs-bounds.png + 05-logs-bounds.txt — dial D scrolls
      events, dial A the transcript, hints flip at the real bounds
- [ ] 06-back-navigation.png — logs → cmd → grid in exact order; opening window returns
- [ ] 07-touch-strip.png + 07-touch-strip.txt — SUMMARY equals the fleet's running keys;
      provider segment values recorded
- [ ] session.webm — the whole run as one recording
- [ ] versions.txt — aiur commit, sidecar version, kernel

Live-run only (an agent workspace cannot produce these)
- [ ] step 4: `aiurdev status` agrees with the dashboard at the same timestamp
- [ ] step 7: strip segments match the dashboard header meters numerically
- [ ] step 2: per-agent state parity with the Units page

Package CI
- [ ] packages/streamdeck: npm ci && npm run lint && npm test && npm run build — all pass
- [ ] streamdeck browser spec: node scripts/run-browser-tests.mjs tests/streamdeck-emulator.browser.spec.mjs — pass
- [ ] streamdeck operator-flow spec: node scripts/run-browser-tests.mjs tests/streamdeck-operator-flow.browser.spec.mjs — pass

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

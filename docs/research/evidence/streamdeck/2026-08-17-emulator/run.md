# Stream Deck emulator proof run

- run started: 2026-08-18T06:25:36.823Z
- run finished: 2026-08-18T06:25:41.277Z
- surface: the real `/streamdeck` LiveView, served by the browser fixture
  server over the fixture fleet. Not a mock of the deck.
- fleet size: 19 agents
- agent controlled in step 4: #1352

## What this run evidences

| Step | Artifact |
|---:|---|
| 1 | `01-start.png` |
| 2 | `02-grid.png`, `02-grid.txt`, then after the live fleet change `02-grid-after-change.png`, `02-units.png`, `02-grid-units-parity.txt` |
| 3 | `03-paging.png` |
| 4 | `04-pause-cmd.png`, `04-pause-grid.png`, `04-pause.txt`, `04-resume.png` |
| 5 | `05-logs-live-end.png`, `05-logs-bounds.png`, `05-logs-bounds.txt` |
| 6 | `06-back-navigation.png` |
| 7 | `07-touch-strip.png`, `07-touch-strip.txt` |
| 1–7 | `session.webm` — the whole run as one recording |

## What this run does not evidence

- `aiurdev status` agreeing with the pause in step 4. It reads a running
  Aiur daemon; an agent workspace must not start one.
- The dashboard header meters as a numeric cross-check for step 7, for the
  reason recorded in `07-touch-strip.txt`.
- Hardware steps 8–11: N/A — #1342 no-go.

Both open items need an Executor-root run. The commit, kernel and sidecar
version this run was captured on are in `versions.txt`.

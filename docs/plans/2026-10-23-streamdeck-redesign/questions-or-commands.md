# Open points and commands

Kevin, 2026-10-23: "enough scope questions, research, write, queue tickets". No question blocks
the start. Each point below has a recommended default; the owning ticket uses that default
unless Kevin changes it on the ticket.

## Cross-ticket points (Executor action)

| # | Point | Recommended default | Owner |
|---|-------|---------------------|-------|
| Q1 | #5181 is in progress (PR #5284, changes requested since 2026-10-19). It fixes only the emulator and adds a third transcript reader. | Park #5181, close PR #5284 with a pointer to SD-303/SD-304, and close #5181 when SD-304 merges. SD-304 carries its acceptance test. | Executor |
| Q2 | `feature_progress` / `epic_progress` server blocks do not exist; #5998/#5999 put them behind browser-only #5996. | Keep native `blocked_by` #5998/#5999 on SD-203/SD-204. Ask the #5998/#5999 owners to land the server block first, or split it out, so the deck does not wait on #5996. | Executor |
| Q3 | SD-207 needs per-instance credentials. Epic #5964 is the umbrella; #5945 (bearer tokens for machine clients) is the real prerequisite. | Native `blocked_by` #5945 only, not the whole epic. #5950 (instance roster) is soft: show stale instances as stale. | Pack |
| Q4 | SD-403 builds on #5589 (PR #5618 changes `acc` to mean remaining). | Native `blocked_by` #5589. Ship SD-401 first if #5589 is late. | Pack |
| Q5 | SD-407 hard blockers #4145 and #5729. | Keep both. Drop #4145 if its server semantics land in #4142; drop #5729 only if the deck adds its own `:streamdeck` authority branch. | SD-407 |
| Q6 | SD-105 deletes the public `GET /api/v1/streamdeck/grid`. | Delete it, say so in the PR body and docs; point users at the Build page payload. | SD-105 |
| Q7 | Voice may still be blocked by MP-E6 when the rest is done. | Accept the feature (SD-901) without voice; keep SD-407/SD-408 open behind their blockers. | SD-901 |
| Q8 | Feature collection registry (`aiur feature create/add`) and queue placement. | Tickets are filed `agent:parked`, `priority:3` with label `feature:streamdeck-redesign`. When promoted (just before MP-N), the Executor runs continuous-build intake: `aiur feature create streamdeck-redesign`, `aiur feature add`, enqueue. | Executor |

## Per-ticket defaults (details in each ticket's "Open points")

- SD-101: `eta_seconds: nil`; a held focus lane is still shown.
- SD-102: register the variable JetBrains Mono woff2; vendor a static TTF only if Skia rejects it.
- SD-103: delete sidecar demo mode in SD-105; full frame per push with hash dedupe.
- SD-104: inline SVG, so page fonts apply.
- SD-201: dial 4 moves one page per detent; dial 1 press is a no-op; long press is 500 ms.
- SD-202: attention-first state order; backlog is `plan` rows only.
- SD-205: merge error+retrying and parked+paused into one key each.
- SD-206: no fallback to `AgentChat.prioritize/1`; turn left = up.
- SD-301: the open PR goes in the shared Build row, so the desktop modal gets it too.
- SD-302: open PR and desktop modal with `xdg-open` from the sidecar.
- SD-303: keep the 2 s tail poll beside the live subscription.
- SD-304: turns only (no PR/CI event keys); N = 7 plus LIVE.
- SD-401: pager label "14 agents · 512 queued", falling back to "14 · 512q".
- SD-403: "closest to limit" is the lower remaining of session and weekly.
- SD-404: meter detail opens from a key; no touch-strip tap.
- SD-406: settings are stored per instance; flash/chime alerts default to command, ci_red, error, usage_limited.
- SD-408: delete `audio/stt.ts` and the `Transcriber` port if `converse.ts` does not import them.

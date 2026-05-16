---
title: CLI terminal typing and SSH alerts
type: fix
status: active
date: 2026-05-16
---

# CLI terminal typing and SSH alerts

## Summary

The CLI typing problem should be treated as a terminal interaction design issue,
not a local redraw optimization bug. The target is native-feeling typing in the
log composer, correct cursor placement, no input-panel growth during typing, and
alert behavior that still produces a useful signal when the user is SSH'd from
Termius on iPad.

## Problem Frame

The current CLI dashboard is useful for monitoring agents, but typing into the
agent log composer still feels wrong. The cursor is visibly offset, typing is
laggy, and previous render-loop changes have regressed. A recent incremental
render attempt made the input area grow by one line per character, which points
to terminal autowrap/cursor-addressing behavior rather than an ordinary string
formatting issue.

Alert sounds have a related environment mismatch: configured sound files play on
the machine running Symphony. When the operator is connected over SSH from
Termius on iPad, host-side audio is not heard on the client.

## Requirements

R1. Typing in the CLI log composer must feel native: ordinary characters,
backspace, and cursor movement should not require full dashboard redraws or
snapshot refreshes.

R2. The composer cursor must land on the actual insertion point while typing,
not one row lower or one column to the right.

R3. The input panel must not grow or drift while typing. Repainting the composer
must preserve the existing panel position and height unless the text genuinely
wraps or includes a newline.

R4. Terminal rendering must account for autowrap-sensitive terminals by avoiding
incremental writes that rely on filling the final terminal column.

R5. Sound-bearing alerts must keep host-side sound playback where available, but
also emit a terminal-visible/audible fallback so SSH clients can signal the
operator even when host audio is remote.

R6. Fixes must be validated in a real `agents` CLI session before declaring the
typing behavior fixed.

## Key Decisions

- Separate typing responsiveness from normal dashboard refresh. Full dashboard
  frames remain appropriate for tracker/agent state updates, but keystrokes need
  a smaller terminal update path.
- Treat terminal behavior as part of the product surface. ANSI output that works
  in a string test is not sufficient if it triggers autowrap or cursor drift in
  real terminals.
- SSH alert support is a fallback signal, not audio streaming. Symphony should
  not try to stream configured sound files over SSH in this pass.

## Scope Boundaries

In scope:
- CLI composer cursor placement.
- CLI composer typing latency.
- Input-panel stability during typing.
- Terminal fallback for sound-bearing alerts.
- Focused regression tests plus real `agents` CLI verification.

Out of scope:
- Replacing the CLI with a new TUI framework.
- Redesigning the whole dashboard layout.
- Streaming arbitrary audio from the host to an SSH client.
- PubSub, queue delivery, or agent lifecycle behavior unrelated to typed input
  and alert signaling.

## Success Criteria

- In a real `agents` session, typing multiple characters in the log composer
  does not visibly expand the input area.
- Cursor placement matches the text insertion point during typing.
- Typing responsiveness is not gated on the normal dashboard refresh interval.
- Sound-bearing alerts still log and play host-side sounds when possible, and
  also emit a terminal fallback signal.

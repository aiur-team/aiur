---
title: CLI terminal typing and SSH alert fallback
type: fix
status: active
date: 2026-05-16
origin: docs/brainstorms/2026-05-16-cli-terminal-typing-requirements.md
branch: bug-fixes
---

# CLI terminal typing and SSH alert fallback

## Summary

Fix the CLI log composer by separating keystroke repainting from full dashboard
rendering while respecting terminal autowrap behavior. Keep existing alert sound
playback, and add a terminal fallback for SSH clients.

## Requirements Trace

- R1, R3, R4: Composer typing must avoid full-frame redraws and must not expand
  the input area during ordinary typing.
- R2: Cursor placement must match the insertion point.
- R5: Sound-bearing alerts need an SSH-visible fallback.
- R6: Verify with a real `agents` CLI session before marking fixed.

## Current Context

The current dashboard already caches snapshots and has a recent input-only
render path in progress. That path is directionally right but unsafe because it
can still write autowrap-sensitive lines and must be verified in an actual
terminal. Alert playback currently uses host-side sound playback, which cannot
be heard on the SSH client when the operator is connected from Termius.

## Key Technical Decisions

- Keep full-frame rendering for normal dashboard refresh, navigation, and layout
  changes.
- Use input-panel repainting only when the composer height remains stable. If
  typing changes the panel height, fall back to a full cached frame.
- During incremental input repainting, clear and rewrite each input-panel row
  with cursor addressing instead of printing newline-separated full-width text.
- Avoid writing into the final terminal column during incremental repainting to
  reduce autowrap risk across SSH clients and terminal emulators.
- Emit a terminal bell for sound-bearing alerts in addition to existing
  host-side playback.

## Implementation Units

### U1: Stable Composer Repaint

Files:
- Modify `elixir/lib/symphony_elixir/status_dashboard.ex`
- Test `elixir/test/symphony_elixir/status_dashboard_view_test.exs`

Approach:
- Track the last full-frame cursor position so the input panel can be located.
- Repaint only the input panel for ordinary character, backspace, and cursor
  movement when the panel height is unchanged.
- Clear each row before writing it, and keep incremental repaint width below the
  terminal's final column.
- Fall back to a full cached frame when layout height changes.

Test scenarios:
- Typing uses the input repaint path rather than the full-frame render path.
- Cursor location after typing matches the expected insertion point.
- Incremental rows are rendered at stable absolute positions.

Verification:
- `mix test test/symphony_elixir/status_dashboard_view_test.exs`
- Real `agents` CLI typing smoke test.

### U2: SSH-Friendly Alert Fallback

Files:
- Modify `elixir/lib/symphony_elixir/alerts.ex`
- Test `elixir/test/symphony_elixir/alerts_test.exs`

Approach:
- Keep configured sound selection and host-side playback unchanged.
- Emit a terminal fallback only for alerts that selected a sound.
- Keep tests isolated with an injectable notifier.

Test scenarios:
- A sound-bearing alert invokes both the sound player and the terminal fallback.
- Silent alerts remain silent.

Verification:
- `mix test test/symphony_elixir/alerts_test.exs`

### U3: Validation Loop

Files:
- No source ownership beyond U1 and U2.

Approach:
- Run focused tests for dashboard rendering and alerts.
- Run build and lint after formatting.
- Run `agents` interactively enough to open the log composer and type multiple
  characters, confirming the input area stays stable.

Verification:
- `mix build`
- focused ExUnit tests
- `mix lint`
- `agents` CLI smoke test

## Scope Boundaries

In scope:
- Existing CLI dashboard renderer and input composer.
- Existing alert emission path.

Out of scope:
- New TUI framework adoption.
- Web dashboard chat changes.
- SSH audio streaming.
- Queue or PubSub behavior.

## Risks

- Terminal behavior varies by emulator and SSH client. The plan reduces
  autowrap risk but still requires manual verification in a real terminal.
- The automated tests can prove the selected renderer path and cursor math, but
  they cannot fully prove interactive terminal feel.

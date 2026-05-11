# Interactive CLI Requirements

## Context

Symphony's current foreground CLI is a status dashboard that renders one complete ANSI frame at a time from orchestrator snapshots. It works well as a passive monitor, but it cannot currently keep selection state, react to keypresses, or show a focused log view for one agent.

The next product slice is current-project only. Multi-profile navigation is explicitly deferred.

## User Goals

- Navigate the active agents list with `j`/`k` and arrow keys.
- Select agents with up/down-style movement.
- Press right or enter to open a focused log view for the selected agent.
- Press left or escape to return to the agents overview.
- Keep the current foreground CLI behavior as the default `agents` experience.
- Avoid making the repo depend on a specific agent provider or issue tracker.

## Non-Goals

- Do not build multi-project/profile switching in the first slice.
- Do not replace the web UI.
- Do not require a new daemon just to use keyboard navigation.
- Do not make the terminal UI depend on provider-specific concepts like Codex, Claude, GitHub, or Linear.

## TUI Options Researched

### Keep Native ANSI Rendering

Keep the existing `StatusDashboard` terminal output path, but split it into a small stateful UI layer:

- snapshot model extraction
- overview renderer
- log renderer
- key event reader
- view state transitions

This is the lowest-risk first slice because it preserves existing string/snapshot tests and avoids new native dependencies. It still requires changing the current render loop from "format a complete passive frame" to "format a frame from snapshot plus UI state."

### ExRatatui

ExRatatui is the most capable full TUI option found. It provides Elixir bindings to Rust ratatui, supports drawing widgets, polling keyboard/mouse/resize events, OTP-supervised apps, and headless test rendering.

This is attractive if Symphony wants a richer terminal app with tabs, panes, scrollbars, text input, and eventually remote TUI sessions. The cost is a new NIF dependency and a larger rewrite of the current dashboard renderer.

### Owl

Owl is a good command-line UI toolkit for formatted output, prompts, tables, spinners, progress bars, and live-updating multiline blocks. It is not the best fit for this feature because the requested interaction is a fullscreen event-loop application with persistent selection state and log navigation.

### Ratatouille

Ratatouille has the right conceptual model for a TUI: init/update/render callbacks and terminal events. The concern is dependency age and its termbox foundation. It is less attractive than ExRatatui for new work.

### TermUI

TermUI appears promising: direct-mode, Elm-style, BEAM-focused, with widgets such as log viewers and scrollable viewports. It is newer and less proven than ExRatatui, so it is a candidate to revisit after the first slice rather than the safest immediate foundation.

## Recommendation

Use a full TUI foundation now, with ExRatatui as the preferred library.

The first interactive slice is simple, but the expected direction includes selecting agents, live log panes, pausing agents, messaging agents, split panes, richer controls, and possibly remote terminal access. Those features need a real event loop, focus model, layout engine, scrollable regions, and testable terminal rendering. Building those primitives ourselves would create a private TUI framework inside Symphony.

The implementation should still preserve the current status dashboard behavior as a fallback/passive mode, but the foreground `agents` experience should move toward a supervised ExRatatui app:

1. Add ExRatatui and prove it works in the repo with a small current-project dashboard shell.
2. Extract the existing dashboard data formatting into provider-agnostic presenter functions that both the web UI and TUI can consume.
3. Build the first TUI screen with an agents list, selected row state, and overview metrics.
4. Add a focused log view for one agent using shared log loading/parsing logic.
5. Keep the first slice current-project only; defer profile/project switching to the existing ticket.

This makes the first PR larger than a native key reader, but it avoids throwing away the first implementation as soon as the CLI needs split panes and richer interactions.

## Deferred Ticket

Profile switching is tracked separately:

- https://github.com/its-everdred/symphony/issues/6

## Acceptance Criteria

- `agents` launches the current project foreground CLI.
- With active agents, the overview visibly indicates one selected agent.
- `j`, down arrow, and similar down movement select the next agent.
- `k`, up arrow, and similar up movement select the previous agent.
- Right arrow or enter opens a single-agent log view.
- Left arrow or escape returns to the overview.
- Empty-agent state remains clean and does not crash on navigation keys.
- Passive rendering still works in non-interactive or disabled-dashboard contexts.

## Sources

- ExRatatui docs: https://hexdocs.pm/ex_ratatui/ExRatatui.html
- ExRatatui overview: https://hexdocs.pm/ex_ratatui/readme.html
- Owl docs: https://hexdocs.pm/owl/readme.html
- Ratatouille README: https://github.com/ndreynolds/ratatouille
- TermUI discussion: https://elixirforum.com/t/termui-a-direct-mode-terminal-user-interface-framework-with-components/73464

# Live Code Diffs Requirements

Created: 2026-05-18

## Summary

Show agent file edits as compact, inline diff entries in the conversation pane so operators can see what changed as the agent works without switching to `git diff` or waiting for a PR.

## Problem Frame

The conversation pane already surfaces agent messages and shell activity, but file edits are currently invisible in the live view. This hides the highest-signal operational information from the operator during an active run.

## Requirements

R1. The pane shows file-change events inline in the transcript stream.

R2. Each file-change entry includes an action label, file path, added/removed line summary, and diff hunk body with line numbers and context.

R3. Added and removed lines are visually distinguished with subtle green and red backgrounds while keeping the diff readable in terminal themes.

R4. Large diffs are truncated in the live pane with an explicit omitted-line indicator.

R5. Multi-file diffs render as separate per-file blocks so the operator can scan each changed path independently.

R6. Full raw agent events remain in the existing per-workspace event log; the live pane renders a compact view derived from those events.

## Key Decisions

- Use the agent event stream as the source of truth for live diffs. For Codex, the first implementation targets `turn/diff/updated`, which already represents the turn's current diff.
- Render inline in the existing chat scroll. This matches the reference shape and avoids adding another pane mode before the first version proves useful.
- Truncate in the renderer rather than dropping events at capture time. The raw event log keeps full payloads, while the UI stays compact.
- Treat commits, pushes, and other shell milestones as command events, not diff events. They do not directly describe file content changes.

## Assumptions

- Codex emits `turn/diff/updated` during file-editing turns often enough to make the live view useful.
- Claude-specific file edit events can be added later using the same transcript event and renderer shape if needed.
- A fixed collapsed/truncated view is enough for this issue; interactive expansion can follow after the rendering primitive exists.

## Scope Boundaries

- No popup, side-pane, or expand-on-keystroke workflow in this pass.
- No filesystem watcher or periodic `git diff` polling.
- No attempt to reconstruct diffs from arbitrary shell commands.
- No changes to PR diff generation or GitHub behavior.

## Success Criteria

- Synthetic Codex diff events become transcript diff events.
- The viewport renders update, create, and delete-style diff blocks with summary and hunk rows.
- Long diff blocks show a clear truncation row.
- Existing chat and command rendering behavior remains intact.

# T-059: Website: surface newly-catalogued features

**Phase:** 5
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:5` `complexity:2`

## Problem / context

The marketing site at `website/` undersells the feature set that the
feature inventory catalogued. The six feature cards in
`website/index.html` (the `.below` section, lines 94–151) still describe
the product in terse, early copy: the shared event bus is reduced to
"auto-pub/sub", remote control ("Take the Wheel") does not name that it
is a takeover of a running agent, multi-backend routing is a trailing
"Supports Claude and Codex", and blocker declarations are never named at
all. The inventory now documents these as first-class capabilities
(event bus emit/subscribe + blocker coordination, remote control,
prewarm, live dashboards, multi-backend model routing).

This ticket rewrites the body copy of the six existing feature cards so
the site accurately surfaces those capabilities. It is a **content-only**
change: the copy text of the six `<p>` bodies in the `.below` section is
the entire edit surface. No layout, no CSS, no terminal-sim code, and no
card count changes — the grid stays a clean six-card 3×2 (collapsing 3→2
at 640px and 2→1 at 440px per `website/src/styles.css`), so the
byte-identical golden snapshot (`npm run assert`, which snapshots the
terminal sim from `website/src/dashboard.ts`, not `index.html`) is
untouched.

The only editable file is `website/index.html`. All marketing copy lives
there; `website/src/` contains no feature-card text (verified by grep).

## Scope (exact)

Edit **only** `website/index.html`. Replace the inner text of the six
feature-card `<p>` elements in the `.below` section. Change nothing else
in the file — keep every `<h3>` heading, every `<svg>` icon, every `.idx`
number, the `.summary` line, the `.signoff` line, and the footer exactly
as-is. Preserve the `<a href="https://opencode.ai" ...>Opencode</a>`
anchor inside card 04 verbatim (do not alter its `href`, `target`, or
`rel`).

Make these six exact replacements (old → new):

1. Card 01 (line 104), inside `<h3>Issue Monitoring</h3>`:
   - OLD: `<p>Dispatch agents automatically via GitHub or Linear tickets.</p>`
   - NEW: `<p>Point aiur at a GitHub or Linear backlog and it dispatches one coding agent per open ticket automatically.</p>`

2. Card 02 (line 112), inside `<h3>Shared Bus</h3>`:
   - OLD: `<p>Agents auto-pub/sub to dependency events, unblocking work early.</p>`
   - NEW: `<p>Agents emit and subscribe to events on a shared bus, declaring blockers and unblocking each other's work the moment a dependency lands.</p>`

3. Card 03 (line 120), inside `<h3>Optimize Effort</h3>`:
   - OLD: `<p>Story points guide model sizes and skills. Supports Claude and Codex.</p>`
   - NEW: `<p>Story points route each ticket to the right model size and skills, across both Claude and Codex backends.</p>`

4. Card 04 (line 128), inside `<h3>Take the Wheel</h3>`:
   - OLD: `<p>Drive at any moment via pre-warmed <a href="https://opencode.ai" target="_blank" rel="noopener">Opencode</a> sessions in configurable tmux panes.</p>`
   - NEW: `<p>Take remote control of any agent at any moment through a pre-warmed <a href="https://opencode.ai" target="_blank" rel="noopener">Opencode</a> session in a configurable tmux pane.</p>`

5. Card 05 (line 136), inside `<h3>Smart Alerts</h3>`:
   - OLD: `<p>Customize notifications and sounds when agents finish, stall, or need a decision.</p>`
   - NEW: `<p>Customize notifications and sounds that fire when agents finish, stall, or need a decision from you.</p>`

6. Card 06 (line 144), inside `<h3>Live Dashboard</h3>`:
   - OLD: `<p>Shareable web view of every agent, event, and progress bar.</p>`
   - NEW: `<p>A shareable web dashboard tracks every agent, event, and progress bar live.</p>`

Do not add, remove, or reorder cards. Do not touch `website/src/styles.css`.

## Files

- Create: (none)
- Modify: `website/index.html`
- Test: (none — see Characterization-tests; guard is `cd website && npm run assert`)

## Out of scope

- `website/src/dashboard.ts`, `website/src/simData.ts`,
  `website/src/terminal.ts` — the terminal sim and its render pipeline.
  Do not touch.
- `website/src/styles.css` — no CSS changes. The six-card grid layout and
  its responsive breakpoints stay exactly as-is. If you believe a CSS
  change is required, stop and comment the blocker on the issue.
- `website/src/flowField.ts`, `website/src/main.ts` — hero canvas and
  install-tab logic. Untouched.
- `website/scripts/*` and `website/scripts/dashboard-golden.json` — do not
  regenerate the golden snapshot.
- The hero tagline, `.summary` line, `.signoff` line, footer, favicons,
  and webmanifest. Untouched.
- The VitePress docs package (T-055 – T-058) — unrelated.

## Inventory-IDs

- **FI-SITE-041** · Marketing content sections (`website/index.html:94-165`)
  — the summary line, six numbered feature cards, signoff, and footer;
  the features grid collapse (3→2 at 640px, 2→1 at 440px). This ticket
  edits only the six card `<p>` bodies within this feature.

## Characterization-tests

**None.** The website has no characterization tests under
`src/test/aiur/regression/` (those cover the Elixir TUI only). The
website's guard is `cd website && npm run assert`, a byte-identical golden
snapshot of the terminal sim rendered from `website/src/dashboard.ts`; it
does not cover static `index.html` marketing copy, so a text-only edit to
the feature-card `<p>` bodies cannot change its result.

## Acceptance criteria

- `git diff --name-only` (against the branch base) lists **exactly one**
  file: `website/index.html`. No other file — especially not
  `website/src/dashboard.ts`, `simData.ts`, `terminal.ts`, `styles.css`,
  `flowField.ts`, `main.ts`, or any file under `website/scripts/` — appears.
- `website/index.html` still contains exactly six `<div class="feat">`
  cards: `grep -c 'class="feat"' website/index.html` prints `6`.
- All six headings are unchanged: `grep -c '<h3>Issue Monitoring</h3>\|<h3>Shared Bus</h3>\|<h3>Optimize Effort</h3>\|<h3>Take the Wheel</h3>\|<h3>Smart Alerts</h3>\|<h3>Live Dashboard</h3>' website/index.html` prints `6`.
- The five named capabilities are surfaced in the new copy (each grep
  returns a match in `website/index.html`):
  - event bus + coordination: `grep -q 'emit and subscribe' website/index.html` **and** `grep -q 'declaring blockers' website/index.html`
  - remote control: `grep -q 'Take remote control' website/index.html`
  - prewarm: `grep -q 'pre-warmed' website/index.html`
  - multi-backend routing: `grep -q 'Claude and Codex backends' website/index.html`
  - live dashboard: `grep -q 'shareable web dashboard' website/index.html`
- The Opencode anchor is preserved verbatim:
  `grep -q '<a href="https://opencode.ai" target="_blank" rel="noopener">Opencode</a>' website/index.html`.
- No new files are created and no code modules are added, so the
  per-file line/function-length and per-module test-coverage clauses are
  vacuously satisfied (this is a static-copy edit).
- `cd website && npm run typecheck && npm run assert && npm run build` all
  exit 0; `npm run assert` prints all-OK (golden byte-identical).

## Verification

### Agent gate (run all, from src/)

```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```

This ticket touches only `website/`, so ADD (and treat as the real gate):

```
cd website && npm run typecheck && npm run assert && npm run build
```

`npm run assert` must print all-OK and exit 0 (golden snapshot
byte-identical). No docs-package build applies (this ticket does not touch
the VitePress package).

### At-merge (reviewer)

- `Check:` `git show --stat` on the merge commit lists only
  `website/index.html`.
- `Check:` re-run `cd website && npm run assert` — exits 0, golden
  unchanged.
- Visual spot-check the `.below` features grid renders the six updated
  cards with correct copy, headings, and icons, and the Opencode link
  still points to https://opencode.ai.
- Device-verify the responsive features grid at mobile widths. Per
  `website/AGENTS.md`:
  > **`scripts/shot.ts` is NOT sufficient for layout verification.** It
  > renders a frame in headless Chromium at a fixed `1100x760` window —
  > great for eyeballing pane *content*, useless for responsive/mobile
  > behavior.
  Use device emulation (agent-browser or Chrome CDP
  `Emulation.setDeviceMetricsOverride`, `mobile: true`, real DPR) to
  confirm the six-card grid collapses cleanly (3→2 at 640px, 2→1 at
  440px) with no card overflow or clipped copy after the text change.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.

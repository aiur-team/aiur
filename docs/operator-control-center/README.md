# Operator Control Center — planning branch

Branch `occ-planning` (off `origin/v2`). Docs-only; no code yet. This is the planning home for
the **Operator Control Center (OCC)** — extending Aiur's existing LiveView dashboard into a
decision-inbox + fleet-state + history control surface for a human operator overseeing the fleet.

## Layout
| File | What it is | Owner |
|---|---|---|
| `00-prd.md` | The feature scope / PRD (the source of truth for what OCC is) | operator's doc |
| `01-brainstorm-and-decomposition.md` | CE-brainstorm grounding, the scoping decisions, and the ticket breakdown | this session |
| `claude-design-prompt.md` | Ready-to-send prompt → Claude builds a self-contained HTML mock with example data | design handoff |
| `tickets/OCC-*.md` | One design doc per implementation ticket (written before exporting to GitHub) | *coming from ce-plan* |

## Decisions locked (from the brainstorm)
1. **Full scope is v1**, decomposed into **many parallelizable tickets** (not a single mega-PR).
2. **Claude designs a mock** (HTML artifact). The **UI ticket is blocked** on the operator sending that mock's URL; the agent then productionizes it into LiveView.
3. **Link, don't merge**, with #930's offline telemetry/analytics dashboard — two separate surfaces.
4. Tickets route to **codex 5.6 sol / max** (heavy model).

## Workflow (where we are → what's next)
1. ✅ Branch + design prompt written.
2. ✅ PRD + brainstorm + decomposition on the branch (this commit).
3. ⏳ **Operator sends the design prompt to Claude** → gets a mock URL (in progress).
4. ⏳ **ce-plan → ticket exploration**: fan out research agents to turn each OCC-N in the decomposition into a full `tickets/OCC-*.md` design doc (grounded against the real modules), with dependencies marked.
5. ⏳ Export the ticket docs to GitHub issues (codex sol/max), UI ticket blocked on the mock URL.

Nothing is dispatched to the fleet until the ticket docs are written and reviewed.


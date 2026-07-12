# Operator Control Center

This is the planning and implementation-contract home for the **Operator
Control Center (OCC)** — extending Aiur's existing LiveView dashboard into a
decision inbox, fleet-state view, and history control surface for a human
operator overseeing the fleet.

## Layout

| File | What it is | Owner |
|---|---|---|
| `00-prd.md` | The feature scope / PRD (the source of truth for what OCC is) | operator's doc |
| `01-brainstorm-and-decomposition.md` | CE-brainstorm grounding, the scoping decisions, and the ticket breakdown | this session |
| `02-occ-0-audit-and-design-decisions.md` | Accepted architecture audit and cross-ticket design decisions | OCC-0 |
| `03-occ-1-decision-contract.md` | Durable request schema/store handoff | OCC-1 |
| `04-occ-3-answer-delivery-contract.md` | Answer, dispatch, transport, and agent acknowledgement handoff | OCC-3 |
| `05-occ-8-decision-revision-contract.md` | Append-only revision, corrective dispatch, and blocking follow-up handoff | OCC-8 |
| `claude-design-prompt.md` | Ready-to-send prompt → Claude builds a self-contained HTML mock with example data | design handoff |

## Decisions locked (from the brainstorm)

1. **Full scope is v1**, decomposed into **many parallelizable tickets** (not a single mega-PR).
2. **Claude designs a mock** (HTML artifact). The **UI ticket is blocked** on the operator sending that mock's URL; the agent then productionizes it into LiveView.
3. **Link, don't merge**, with #930's offline telemetry/analytics dashboard — two separate surfaces.
4. Tickets route to **codex 5.6 sol / max** (heavy model).

## Implementation status

OCC-0 established the architecture decisions, OCC-1 delivered the durable
Decision request store, OCC-3 added persist-before-dispatch answer delivery,
and OCC-8 extends that same audit/outbox with ordered revisions. Follow the
numbered contract docs rather than reconstructing behavior from individual
implementation tickets. The inbox UI remains gated on its design handoff;
API, fleet, and metrics tickets build on these contracts independently as
shown in the decomposition.

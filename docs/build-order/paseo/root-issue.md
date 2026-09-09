# BO: aiur-paseo — chat with any aiur agent from the Paseo app

Deliver an opt-in `aiur-paseo` package so an Executor can chat with any aiur agent from the Paseo mobile or desktop app while aiur keeps driving the agent, and the TUI and dashboard keep working. One conversation, three views, selectable per agent.

## Finite boundary

This root contains all 15 members: PSO-001 through PSO-015. PSO-014 and PSO-015 are optional tail work and may be closed as not planned without changing the root's completion claim for the core capability, which is proven by PSO-012.

Completion requires every non-optional member implemented, reviewed, green on `main`, merged, documented, and proven after merge through the manual proof in `docs/build-order/paseo/00-design.md` section 12.

## Packaging constraint (operator, 2026-09-09)

Paseo support must not bloat the core package. It ships as a separate npm package, `aiur-paseo`, an app-server sidecar in `packages/aiur-paseo/`, following the `aiur-claude` and `packages/streamdeck` precedents and the findings of the `planning/decompose-packages` research. Core changes are limited to registry data and three small generalizations (generic app-server backend, resume passthrough, generic surface indicator).

## Approved planning authority

- Planning pack: `docs/build-order/paseo/`
- Read first: `docs/build-order/paseo/README.md`, then `00-design.md`
- Spike evidence: `docs/build-order/paseo/01-spike-report.md`
- Origin: `docs/plans/2026-09-09-001-feat-paseo-integration-plan.md`

GitHub is authoritative for live membership and blockers after publication. Native sub-issues are the members; native `blockedBy` edges are the dependency graph.

## Waves

| Wave | Members |
|---|---|
| 1 | PSO-001, PSO-002, PSO-003, PSO-004 |
| 2 | PSO-005, PSO-006, PSO-007, PSO-008 |
| 3 | PSO-009, PSO-010, PSO-011 |
| 4 | PSO-012, PSO-013 |
| 5 | PSO-014, PSO-015 (optional) |

Waves are presentation and rollout guidance. Readiness comes only from native `blockedBy` state.

## Dispatch

No member carries an `agent:*` label at publication. The operator releases a wave by adding `agent:todo` to its members after sign-off.

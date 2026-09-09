# aiur-paseo planning pack

Read this file first. This pack contains the reviewed design and the fifteen issue contracts for the `aiur-paseo` build order. It does not implement anything.

## Status

- Plan version: 1
- Build Order ID: `aiur-team/aiur:aiur-paseo`
- Researched code: aiur `main@8199f5373`, Paseo `getpaseo/paseo@726067b4` (daemon 0.7.2), `aiur-claude` 1.1.0
- Members: 15 (PSO-001 to PSO-015), three lanes (`paseo-core`, `paseo-sidecar`, `paseo-integration`), five waves
- Root issue: filed by the operator after sign-off; see `root-issue.md`
- Dispatch: paused until the operator releases wave 1 by adding `agent:todo`

## Reading order

1. [`00-design.md`](00-design.md), the planning authority: goal, packaging constraint, decisions DEC-001 to DEC-015, the app-server protocol the sidecar implements, Paseo facts, aiur seams, waves.
2. [`01-spike-report.md`](01-spike-report.md), the hands-on spike against a real Paseo daemon on this machine, with verbatim JSON.
3. [`../../plans/2026-09-09-001-feat-paseo-integration-plan.md`](../../plans/2026-09-09-001-feat-paseo-integration-plan.md), the options analysis that chose this path.
4. `tickets/PSO-*.md`, one contract per member.

## Lanes

| Lane | Members | What it owns |
|---|---|---|
| `paseo-core` | PSO-001, PSO-002, PSO-003, PSO-007 | the Elixir changes: generic app-server backend, registry data, surface indicator, resume passthrough |
| `paseo-sidecar` | PSO-004, PSO-005, PSO-006, PSO-009, PSO-010, PSO-011 | `packages/aiur-paseo/`: scaffold, protocol server, Paseo client, turn mapping, tool bridge, resume and surface |
| `paseo-integration` | PSO-008, PSO-012, PSO-013, PSO-014, PSO-015 | docs, end-to-end proof, init wizard, optional permission bridge, optional mid-run move |

## Member contract

Each member issue carries exactly one `complexity:N`, one `model:claude`, one `phase:N`, and one `build-lane:<lane>` label, and no `agent:*` label at publication. The issue body is the ticket doc verbatim. The ticket doc's `Depends on` line is mirrored as native `blockedBy` edges.

## Validation for every member

- `cd src && make all` and `mix specs.check` for Elixir changes.
- `npm ci && npm run lint && npm run typecheck && npm test` in `packages/aiur-paseo/` for package changes.
- `python3 scripts/check-config-docs.py` whenever a config key changes.
- PR body follows `.github/pull_request_template.md`; docs ship in the same PR.
- The manual proof in `00-design.md` section 12 is executed once by PSO-012 and recorded under `evidence/`.

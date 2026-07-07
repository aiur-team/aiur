# T-006A: Verify warm-pool decoupling and update guidance

**Phase:** 1
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:1` `complexity:2`

## Problem / context

Issue #376 already covered and closed the core behavior: `pre_warmed_sessions`
should size only the automatically pre-warmed opencode pool, not cap total
opencode instances or agent concurrency. Current code also appears to expose this
split through `Aiur.Opencode.SlotPolicy.target_count/0`, `max_slots/0`,
`grow_slot/0`, and `Aiur.Opencode.SlotSupervisor.acquire_slot_or_grow/0`.

The remaining problem is stale operator guidance. `.claude/skills/aiur-run/SKILL.md`
still tells operators to set `pre_warmed_sessions` equal to `agent.max_concurrent_agents`
until #376 lands. That causes large runs to pre-spawn too many opencode processes
and increases CPU/FD pressure before any user opens a pane.

## Scope (exact)

Read first:

1. `src/lib/aiur/opencode/slot_policy.ex`
2. `src/lib/aiur/opencode/slot_supervisor.ex`
3. `src/lib/aiur/pane_manager.ex`
4. `.claude/skills/aiur-run/SKILL.md`
5. `docs/refactor/RUNBOOK.md`

Then:

1. Add or update tests proving that `pre_warmed_sessions` controls only the warm pool
   (`SlotPolicy.target_count/0`) while total slot capacity comes from
   `max(max_vertical_panes * 2 - 1, agent.max_concurrent_agents)`.
2. Add or update tests proving that a fully consumed warm pool can grow cold slots on
   demand up to `max_slots` without requiring `pre_warmed_sessions == max_concurrent_agents`.
3. If verification shows the #376 behavior regressed, fix that regression.
4. Update operator guidance so `pre_warmed_sessions` is described as a warm-pool/latency
   dial, not a concurrency cap. Remove the stale equal-values rule once tests prove it is
   no longer true.

## Out of scope

- No broad opencode slot decomposition; T-011 and later Phase 4 tickets own the larger
  slot characterization/decomposition work.
- No change to `agent.max_concurrent_agents` semantics.
- No attempt to pre-warm every possible pane by default.

## Acceptance criteria

- A config with `agent.max_concurrent_agents: 8` and `pre_warmed_sessions: 1` allows
  the slot system to grow beyond the single warm slot on demand, up to the configured
  total slot cap.
- Startup eagerly boots only the warm-pool count, not the max agent count.
- Existing instant-open behavior for already-warmed slots remains intact.
- Operator docs no longer instruct people to set `pre_warmed_sessions` equal to
  `max_concurrent_agents`.
- Tests fail if `pre_warmed_sessions` again becomes the total opencode-instance cap.

## Verification

- `cd src && mix test test/aiur/opencode/slot_policy_test.exs`
- `cd src && mix test test/aiur/regression/attach_fanout_cap_test.exs`
- `cd src && mix test test/aiur/regression/opencode_slots_test.exs` if T-011 has
  already landed; otherwise note that T-011 remains the broader characterization follow-up.
- `cd src && mix compile --warnings-as-errors`

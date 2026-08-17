---
name: aiur-debug
description: "Aiur context overlay for diagnosing runs, daemons, tickets, agents, events, providers, workspaces, dashboards, PRs, and infrastructure with correlated evidence and safe recovery ordering. Compose it with a general debugging skill."
---

# Debug Aiur with correlated evidence

`/aiur-debug` is an **Aiur context overlay**, not a general debugging handbook.
It supplies Aiur topology, evidence locations, join keys, state semantics, safety
boundaries, and recovery ordering. It deliberately delegates reproduction,
hypothesis testing, causal-chain analysis, root-cause method, and fix validation
to the strongest compatible general debugging workflow available.

## Compose skills before investigating

1. Inspect the active skill/capability catalog; do not assume optional packages
   are installed.
2. Load `/aiur-debug` for the Aiur context layer.
3. Load the runtime's native `/debug` skill for the general investigation
   method when the active catalog provides it. The former repo-local narrow
   `/debug` copy was removed so it cannot shadow or conflict with that native
   companion.
4. If `/ce-debug` is available, load it as the preferred structured companion.
   If it is absent, continue with native `/debug`;
   `/aiur-debug` never hard-depends on Compound Engineering.
5. If the implicated provider exposes a native diagnostic skill or capability
   for Codex, Claude, OpenCode, GitHub, Phoenix/LiveView, or the host runtime,
   add it for that layer only.

Resolve overlaps by ownership: this skill wins for Aiur paths, identities,
state meanings, evidence authority, and mutation safety; the general/provider
skill wins for debugging method. Repository `AGENTS.md` and the user's request
remain authoritative over both.

Example composition:

```text
/aiur-debug + /debug
/aiur-debug + /ce-debug                    # when installed
/aiur-debug + /ce-debug + provider debug  # when that layer is implicated
```

## Investigation contract

1. **Preserve first.** Record UTC time, current checkout/config/identity, dirty
   state, relevant log roots, ticket/PR state, and process/tmux state before a
   restart, relabel, retry, reset, or kill can erase evidence.
2. **Choose one symptom boundary.** Run the matching bounded recipe; do not
   search every subsystem indiscriminately.
3. **Join before classifying.** Correlate repository + ticket, then run/instance,
   then agent session/turn/item, then event/delivery or process lineage.
4. **Separate symptom from proof.** A blank dashboard does not prove the daemon
   is down; multiple children do not prove duplicate dispatch; a queued message
   does not prove failed delivery; green checks do not prove mergeability.
5. **Stop at the owning layer.** Once authoritative evidence and
   counter-evidence classify the fault, hand the confirmed layer and evidence
   to `/debug`, `/ce-debug`, or the provider-native workflow for causal analysis
   and fix validation.
6. **Mutate last.** State the blast radius, preserve the evidence that mutation
   destroys, prefer the narrowest reversible containment, and verify the same
   correlation keys afterward.

## Aiur-specific classification rules

- **Aiur orchestration defect:** Aiur created, lost, replayed, misrouted, or
  contradicted authoritative lifecycle state after the tracker/provider input
  is proven correct.
- **Coding-agent/model choice:** one correlated agent session intentionally
  chose a command, branch, model-visible action, or code change; that is not an
  orchestrator duplicate merely because the choice was poor.
- **App-server/OpenCode transport defect:** provider session state is sound but
  JSON-RPC/SSE/pane delivery or rendering diverges.
- **Tracker/GitHub drift:** labels, blocker graph, comments, PR refs, review, or
  checks differ from Aiur's observed snapshot.
- **Repository/application defect:** the correlated agent and orchestration
  lifecycle are sound; the checked-out code, build, test, or app behavior fails.
- **Resource/build contention:** CPU, memory, file descriptors, process trees,
  or the fleet Mix build gate explain delay/failure without duplicate dispatch.
- **Expected behavior:** queueing, `agent:paused`, capacity/load holding,
  backoff, safe-checkpoint delivery, retry budgets, and tracker eventual
  consistency are not defects until their documented terminal or time bound is
  violated.

One running agent may create many child commands. Multiple PIDs, shells, Mix
processes, or OpenCode children alone do **not** prove duplicate dispatch. Join
issue, session/thread, turn, and item/tool-call IDs before filing an Aiur bug.

## References

- [Evidence map, correlation hierarchy, and normalized timelines](evidence-and-correlation.md)
- [Ten bounded diagnostic recipes and safe recovery ladders](diagnostic-recipes.md)
- [Worked examples, diagnostic report, and sanitized bug report](examples-and-reporting.md)

Related maintained guidance:

- [`/aiur-run`](../aiur-run/SKILL.md) — launch and lifecycle ownership
- [`/aiur-monitor`](../aiur-monitor/SKILL.md) — authoritative one-glance run status
- [`/aiur-agent`](../aiur-agent/SKILL.md) — the operating manual: ticket lifecycle, workpad rules, dev loop, and coordination event vocabulary
- [Manual TUI verification](../../../AGENTS.md#manual-testing--the-only-definition)
- [Repository logging contract](../../../src/docs/logging.md)
- [CLI and workspace setup](../../../src/README.md)

## Fast routing

| Symptom | Recipe |
|---|---|
| daemon/startup/tmux/RPC disagreement | 1 |
| ticket not picked up | 2 |
| agent stuck/silent/retried/duplicated/wrong route | 3 |
| message/comment/event/attention/decision missing | 4 |
| PR missing/wrong/stale/conflicted/red/unmergeable | 5 |
| duplicate builds, Mix locks, CPU/load/FD/process pressure | 6 |
| provider startup/resume/usage/model/fallback | 7 |
| dashboard/TUI/listener/auth/LiveView/API disagreement | 8 |
| workspace/bootstrap/git/auth/corruption | 9 |
| event publish/subscribe/replay/dedup/state reconstruction | 10 |

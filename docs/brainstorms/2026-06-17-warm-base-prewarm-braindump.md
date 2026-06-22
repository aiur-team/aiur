# Braindump: eager warm-base pre-warm + loading UI (follow-up to warm-main-base)

**Status:** raw spec capture, NOT a plan. Resume with a fresh `/ce-brainstorm` pass that takes
this file + the shipped feature as input. Do not implement from this directly.

**Feeds into:** `docs/brainstorms/2026-06-17-warm-main-base-requirements.md` and
`docs/plans/2026-06-17-001-feat-warm-main-base-plan.md` (the warm-base feature, U1–U6, already
implemented on branch `feat/warm-main-base`).

---

## The flaw this fixes

The shipped warm-base feature refreshes the base **lazily, per-dispatch**: `ensure_fresh` is only
called from `Aiur.Workspace.create_for_issue` → `maybe_ensure_warm_base`, i.e. *while each agent is
being spun up*. Consequences:

- The base build doesn't start until the **first agent is already being dispatched**.
- That first dispatch eats the entire one-time clone + `base_setup` (deps + full compile) while
  every parallel agent blocks behind it (serialized through the `RepoBase` GenServer).
- Net: the warm base is **not ready before agents begin** — the opposite of the feature's purpose.

The background poll (`repo_base_poll_seconds`) can pre-warm but is off by default and not
synchronized to "before dispatch."

## What we want instead

The warm base must be refreshed **before any agent work begins**, on every `aiur` run.

- **Eager pre-warm at the orchestrator's first cycle**, before `maybe_dispatch` sends anyone. If
  `base_setup` is configured, run `RepoBase.ensure_fresh` once and **hold dispatch** until ready.
  The existing per-dispatch `ensure_fresh` then finds the base fresh → a cheap `git fetch` no-op, so
  agents don't compete or redundantly set up.
- **"All aiur runs begin with this step."** Cheap when the base is already current (just a fetch +
  rebuild-only-if-main-moved); expensive only on the first-ever run per machine.

## Desired UX

- A **loading bar in the agent-list section**, shown **before the agent list populates**.
- **Very concise rotating labels** explaining what's being worked on (e.g. "Fetching latest main…",
  "Installing dependencies…", "Compiling…", "Almost ready…").
- When pre-warm completes, the bar clears and the agent list renders normally.

## Design sketch (directional, not final)

- `Aiur.RepoBase` emits phase events over PubSub: `cloning` → `fetching main` →
  `building (base_setup)` → `ready`.
- `Aiur.Orchestrator` gates its initial dispatch cycle on a "base ready" signal when `base_setup`
  is configured.
- `Aiur.AgentList.App` gains a pre-warm render state (new field threaded through `render/1`'s
  `Map.take`/`Map.put` pipeline — the fragile part) that draws the bar + rotating labels until ready.

## Open decisions (resolve in the brainstorm)

1. **Pre-warm scope:** startup-only blocking (recommended) vs also re-warm + re-block on every
   mid-run `main` advance (e.g. after an agent merges a PR). Startup-only is simpler; mid-run stays
   on the cheap per-dispatch path. *(User dismissed the question — still open.)*
2. **First-run wait:** on a fresh machine the operator stares at the bar through the one-time
   clone + full compile (minutes) before any agent appears. Acceptable? Mitigations (e.g. a
   skip/continue-in-background affordance)?
3. **Label granularity:** `base_setup` is one opaque shell command, so labels during the build are
   **time-rotated generic phrases**, not parsed from build output. The clone/fetch/build *phases*
   are real and event-driven; sub-steps inside the build are not. Confirm this is good enough.

## Constraints carried from the shipped feature

- `base_setup` ownership stays with the dev's hooks (toolchain-neutral); aiur only triggers it.
- Per-dispatch `ensure_fresh` remains as a cheap freshness safety net.
- Warm-base path is gated on `base_setup` being configured — unconfigured repos see no pre-warm
  and no loading bar (cold-clone fallback unchanged).
- TUI render-pipeline fragility (see memory `render_state_takes_explicit`) and label-race risks
  (see memory `chat_text_latency_root_causes`) apply to the agent-list loading state.

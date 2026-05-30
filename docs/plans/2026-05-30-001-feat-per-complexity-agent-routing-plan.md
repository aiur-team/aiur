# Per-complexity agent routing — implementation plan

**Issue:** [#215](https://github.com/its-everdred/aiur/issues/215)
**Complexity:** 4 — cross-cutting (config + boundary + runner + orchestrator + UI surface)
**Date:** 2026-05-30

## Goal

Let a single Aiur run dispatch different issues to different coding-agent
backends (Claude vs Codex) based on each issue's `complexity:N` label, without
breaking the current single-backend default.

This is a config + dispatch change, not a behavior change for any individual
backend. The Claude/Codex chat-render parity that makes mixed-backend output
possible already landed in PR #214 (`claude-app-server-parity`).

## Out of scope

- Changing what Claude or Codex do inside a turn.
- Per-issue backend overrides via comments, GraphQL, or the dashboard. This
  plan only resolves from `complexity:N` labels via static WORKFLOW config.
- Migrating any data — the orchestrator's running map carries the resolved
  backend in-memory, nothing is persisted.

## Implementation units

### 1. Schema: `agent.routing.by_complexity` map

`elixir/lib/aiur/config/schema.ex`

Add a `Routing` embedded schema under `Agent`. Single field
`by_complexity :: %{required(String.t()) => String.t()}`. Validate every
value is `"codex"` or `"claude"`. Normalize keys to strings on cast so
operators can write either `"4": claude` or `4: claude` in YAML.

Default empty map (i.e. `%{}`) so absent/empty routing preserves today's
single-backend behavior.

### 2. Config: per-issue resolver

`elixir/lib/aiur/config.ex`

- `agent_routing/0 :: %{by_complexity: %{String.t() => String.t()}}` — exposes
  the parsed routing map.
- `agent_kind_for_issue(Aiur.Issue.t() | nil) :: String.t()` — looks up the
  issue's `complexity:N` label, returns the routed backend if present in the
  map, otherwise falls back to `agent_kind/0`. `nil`/missing label/missing
  routing all degrade to the global default.

Keep `agent_kind/0` as the global-default getter. Don't change the YAML for
existing callers — the existing config call sites continue to work.

### 3. CodingAgent boundary: per-issue adapter

`elixir/lib/aiur/coding_agent.ex`

- `adapter_for(Aiur.Issue.t() | nil) :: module()`
- `transcript_module_for(Aiur.Issue.t() | nil) :: module()`

Both delegate through `Config.agent_kind_for_issue/1`. The zero-arg
`adapter/0` and `transcript_module/0` stay for callers that genuinely have
no issue context (the `EventHumanizer` adapter, the dashboard top-bar
badge, test scaffolding). They keep using `Config.agent_kind/0`.

The behaviour callbacks (`start_session/2`, `run_turn/4`, `stop_session/1`,
`normalize_event/1`, `send_operator_message/2`) keep their current shapes.
Per-issue dispatch happens in the boundary's public functions and at the
call sites that already hold an issue.

Do **not** add per-issue variants of every boundary function — `AgentRunner`
will resolve the adapter once at session start and call the backend module
directly thereafter (see unit 4). Keeping the boundary thin avoids dragging
the issue argument through every call site.

### 4. AgentRunner: pin backend per session

`elixir/lib/aiur/agent_runner.ex`

In `run_codex_turns/5`, resolve the adapter and transcript module from the
issue **before** `start_session`:

```elixir
adapter = CodingAgent.adapter_for(issue)
transcript_module = CodingAgent.transcript_module_for(issue)
```

Thread both through:

- `start_session` — `adapter.start_session(workspace, worker_host: worker_host)`
- `run_turn` — `adapter.run_turn(app_session, prompt, issue, opts)` at both
  call sites (initial turn at ~404 and operator turn at ~654)
- `stop_session` — `adapter.stop_session(session)` in the `after` block
- `normalize_event` — call the adapter directly from inside
  `codex_message_handler/5`'s closure (close over `adapter`)
- `transcript_event_from/2` — close over `transcript_module` in the same
  handler so the right extractor runs

`send_operator_message` does **not** need an explicit thread-through because
`AgentRunner` doesn't call `CodingAgent.send_operator_message/2` directly —
it goes through `Aiur.Orchestrator.send_operator_message/3` which enqueues
an operator queue item; the item is later delivered as a regular `run_turn`
on the pinned adapter. The orchestrator-side enqueue path is backend-agnostic.

Result: each session uses a single consistent backend end-to-end — there is
no path where a Claude-routed session can hit a Codex transcript extractor.

### 5. Orchestrator: backend-aware default control capabilities

`elixir/lib/aiur/orchestrator.ex` (around lines 3519-3540, 1810)

`default_running_control/0` is called in `spawn_issue_on_worker_host/5`
when building the running-entry map. Change it to take the issue:

```elixir
defp default_running_control(%Issue{} = issue) do
  %{
    can_interrupt: default_can_interrupt?(issue),
    safe_checkpoints: default_safe_checkpoints(issue),
    status: :working
  }
end
```

`default_can_interrupt?` and `default_safe_checkpoints` switch on
`Config.agent_kind_for_issue(issue)` instead of `Config.agent_kind/0`. The
running-entry's `:issue` is set immediately after, so the per-row capability
flags reflect the actual backend.

### 6. UI surface: per-row backend in the agent list

`elixir/lib/aiur/agent_list/app.ex` + `renderer.ex`

The top-bar agent badge (`agent_kind/0` in `app.ex:1305`) stays on the
global default — operators read it as "the default backend for new issues."

Each running-entry summary already exposes `identifier`, `status`,
`work_state`, etc. Add `agent_kind` (resolved via
`Config.agent_kind_for_issue(issue)` at summary build time) and render it as
a small badge in the agent-list row when it differs from the default.

`elixir/lib/aiur_web/live/dashboard_live.ex:132` — same treatment: the
top-bar badge stays on the global default; per-row badges show the
per-issue backend when it differs.

### 7. WORKFLOW config

`elixir/local-workflows/WORKFLOW.aiur.local.md`

Add under `agent:`:

```yaml
agent:
  kind: codex
  routing:
    by_complexity:
      "4": claude
      "5": claude
```

This is the operator's local file (gitignored elsewhere, but the
`.aiur.local.md` is checked in as a documented example) — committing the
update means the next aiur run on this repo will route complexity-4 and -5
issues to Claude.

## Test scenarios

`elixir/test/aiur/config/routing_test.exs` (new)

- Resolver: `complexity:4` label + `"4" -> claude` map → `"claude"`.
- Resolver: `complexity:2` label + no entry → falls back to `agent_kind/0`.
- Resolver: missing label → falls back.
- Resolver: `nil` issue → falls back.
- Schema: malformed `by_complexity` value (e.g. `"4": "weasel"`) → changeset
  error with a clear message.
- Schema: numeric YAML key (`4: claude`) → normalized to `"4"`.
- Schema: absent `routing` block → empty map (current behavior preserved).

`elixir/test/aiur/coding_agent_test.exs` (extend existing)

- `CodingAgent.adapter_for(%Issue{labels: ["complexity:4"]})` returns
  `Aiur.Claude.CodingAgent` when routing maps 4 → claude.
- `CodingAgent.adapter_for(%Issue{labels: ["complexity:2"]})` returns the
  default backend.
- `CodingAgent.transcript_module_for/1` mirrors the adapter routing
  (claude → `Aiur.Claude.Transcript`, codex → `Aiur.Codex.Transcript`).

`elixir/test/aiur/orchestrator_*_test.exs`

- Spawning a `complexity:4` issue while the global `agent.kind` is `codex`
  produces a running entry whose `control.safe_checkpoints` matches the
  Claude default (`[:notification]`), not Codex's
  (`[:notification, :tool_result]`).

`elixir/test/support/test_support.exs`

- Extend the WORKFLOW writer to accept an `agent_routing:` override so the
  new tests can configure routing inline.

## Risks

1. **Mid-turn label change.** If the issue's `complexity:N` label flips after
   `start_session`, the running session keeps using the originally-pinned
   backend. That's the intended behavior — switching backends mid-session
   would require restarting the agent. Document this in the WORKFLOW
   example.

2. **Renderer compatibility.** Existing tests assert `agent_kind` at the
   global level (`agent_list/renderer_test.exs`). Adding per-row badges
   shouldn't change those assertions. New tests cover the per-row badge.

3. **Test support drift.** `test_support.exs` hardcodes `agent_kind: "codex"`
   in many places. The routing addition must not break tests that don't
   pass `agent_routing:`. Default the override to `%{}`.

4. **Hot-path cost.** `Config.agent_kind_for_issue/1` runs once at
   `start_session` and once per running-entry build — both cold paths, so
   the per-call cost of reading `Config.settings!/0` is fine.

## Backwards compatibility

- `Aiur.Config.agent_kind/0` unchanged.
- `Aiur.CodingAgent.adapter/0` / `transcript_module/0` unchanged.
- WORKFLOW without `agent.routing.by_complexity` → all issues route to the
  global default → matches today's behavior bit-for-bit.

## Rollout

Single PR, single merge. No feature flag — the routing map is opt-in: an
empty map gives the same behavior as today, so the change is safe to ship
behind a no-op config until the operator adds the routing block.

---
title: "feat: Per-issue agent routing (complexity + model override, registry-driven)"
type: feat
status: active
date: 2026-05-30
deepened: 2026-05-30
origin: elixir/docs/brainstorms/2026-05-30-per-complexity-agent-routing-requirements.md
---

# feat: Per-issue agent routing

## Overview

Replace the single global coding-agent backend (`agent.kind`) with **per-issue** backend selection. Two signals, in precedence order:

1. An explicit **`model:<backend>`** label on the issue (`model:claude` / `model:codex`) — a hard per-issue override.
2. The issue's **`complexity:N`** label, mapped through a WORKFLOW `agent.routing` table (this repo seeds `4,5 → claude`, everything else Codex).
3. Fallback to the global `agent.kind` when neither applies.

Both backends run concurrently in one aiur run because each issue resolves its own backend, fixed for the issue's whole lifetime (including resumed and operator-queued turns).

**Encapsulation is a first-class goal of this change.** Backend dispatch is centralized in a single **backend registry** (`Aiur.CodingAgent.backends/0`) that maps each backend string to its modules and delivery policy. Validation, dispatch, delivery policy, and the known-backend allowlist all derive from this one map. Adding a future model (e.g. a real `opencode` coding-agent, or a new provider) becomes **one registry entry**, not edits across five `case` statements. The registry ships wired for `codex` and `claude` only; it is *structured* to accept more (see Key Decisions → opencode).

The mechanism: `Aiur.CodingAgent.backend_for/1` reads the override tag, then the routing table, then the fallback, and returns a backend **string**. The string is resolved **once** when an issue's session starts, stored **in the session**, and recovered from the session on every subsequent turn — so resume and queue paths never re-resolve and can never flip mid-run. Each dispatch site looks the string up in the registry and **fails loud** on an unknown backend rather than silently defaulting.

---

## Problem Frame

`Aiur.CodingAgent.adapter/0` and `transcript_module/0` (`elixir/lib/aiur/coding_agent.ex:24,39`) switch on `Aiur.Config.agent_kind()` — one global value per run. Other functional sites read the same global. So a run is all-Codex or all-Claude; you can't send hard tickets to Claude and routine ones to Codex in the same session, and a developer can't pin one specific issue to a model. Worse, the existing dispatch is a binary `"codex" -> Codex.* ; _ -> Claude.*`, so any non-codex string silently resolves to Claude — a latent footgun this change must not multiply across new per-issue sites. See origin: `elixir/docs/brainstorms/2026-05-30-per-complexity-agent-routing-requirements.md`.

---

## Requirements Trace

- R1. Per-issue backend resolution: `model:<backend>` override → `complexity:N` routing table → `agent.kind` fallback. (origin R1, extends with override)
- R2. Every **live** functional `agent_kind` read becomes per-issue: agent process (adapter), transcript_module, normalize_event, orchestrator `can_interrupt`/`safe_checkpoints`. (origin R2 — see R2-note on the humanizer)
  - **R2-note:** origin R2 also listed `event_humanizer`. The `Aiur.EventHumanizer` dispatcher seam has **zero live callers** (verified: `event_humanizer.ex:23` is unreferenced; `agent_log.ex` humanizes via its own private function). There is therefore no humanizer split-brain to fix. U5 is a verification-and-remove unit, not a per-issue migration.
- R3. Configurable routing table in WORKFLOW `agent.routing`, schema-validated, shaped **level → backend**; this repo seeded `4,5 → claude`. (origin R3)
- R4. Backward compatible: no routing table and no override tags ⇒ identical to today (all issues use `agent.kind`). (origin R4)
- R5. Concurrency safe: two issues resolving to different backends run in one aiur run without interference; backend is fixed per issue across all turn paths. (origin R5)
- R6. `make all` stays green (compile-Werror, format, lint, test, dialyzer).
- R7. **Extensibility:** adding a backend is a single registry entry. Validation, dispatch, and delivery policy derive from the registry; no hardcoded `"codex"|"claude"` allowlist duplicated across sites. Unknown backends fail loud, never silently default. (operator directive, 2026-05-30)
- R8. **Per-issue model override:** a `model:claude` / `model:codex` label forces that backend for the issue, overriding complexity routing. Override tags use their own `model:` namespace (not `agent:`, which is the state-label prefix). (operator directive, 2026-05-30)

**Origin actors:** Operator (sets routing table, complexity labels, and optional `model:` overrides), Orchestrator/AgentRunner (resolves once at session start + drives backend).
**Origin flows:** F1 — issue enters `agent:todo` → backend resolved (override → complexity → fallback) at session start → that backend used for the issue's agent/transcript/normalize/delivery-policy across all turns → multiple backends concurrent.

---

## Scope Boundaries

- **Display surfaces** (`presenter.ex:189`, `dashboard_live.ex:472` agent badge) keep reading the global `agent.kind` — no per-issue UI badge in this change. (Functional delivery policy in the orchestrator **is** in scope per R2; only the display badges are deferred.)
- **Routing signals** are limited to the `model:` override and the `complexity:` label. No cost budgets, priority, or per-label allowlists. (The `model:` override is the deliberate escape hatch for "this specific issue should go elsewhere" without adding a new routing axis.)
- **No auto-classification** of complexity — the operator sets the label; we only read it.
- **opencode is not wired as a coding-agent backend** in this change (it has no `CodingAgent` adapter today; it is the conversation/serve surface). The registry is structured so adding it later is one entry; routing to it now is rejected at config load with a clear error. (See Key Decisions.)

### Deferred to Follow-Up Work

- Per-issue agent badge in the AgentList/dashboard UI.
- Wiring `opencode` (or any new provider) as a real routable coding-agent backend: a one-registry-entry change plus building that adapter/transcript, out of scope here.

---

## Context & Research

### Relevant Code and Patterns

- `elixir/lib/aiur/coding_agent.ex:24,39` — `adapter/0`, `transcript_module/0`, `normalize_event/1`; the binary `"codex" -> Codex.* ; _ -> Claude.*` seam to replace with a registry.
- `elixir/lib/aiur/config.ex:82` — `agent_kind/0` reads `settings!().agent.kind`. Add `agent_routing/0` beside it.
- `elixir/lib/aiur/config/schema.ex:154-199` — `Schema.Agent` embedded schema. `field(:max_concurrent_agents_by_state, :map, default: %{})` + `Schema.normalize_state_limits/1` + `Schema.validate_state_limits/2` (`:168,196,197`) is the **exact precedent** for a validated `routing` map field (normalize keys, validate values).
- `elixir/lib/aiur/github/client.ex:467-483` — `extract_priority/1` + `parse_priority_label/1` use an anchored `~r/^priority:(\d+)$/` against `label_names`, with a dedicated parser in their own `priority:` namespace. **This is the precedent to mirror** for both `complexity:N` parsing and the `model:<backend>` override tag — a sibling namespace with its own anchored parser, never overloading `agent:`.
- `elixir/lib/aiur/github/client.ex:457` — `extract_state/2` matches **any** `agent:`-prefixed label as the issue's workflow state (first match wins). This is *why* override tags must not use `agent:` — an `agent:claude` label would be misread as a state. Override tags use `model:`.
- `elixir/lib/aiur/agent_runner.ex` — per-issue runner. **Two** `CodingAgent.run_turn` call sites: the initial path (`do_run_codex_turns`, holds the turn context) **and** `run_queue_item_turn` (`:654`, operator/queue-delivered turns) which rebuilds its handler fresh from `session_workspace`/`session_worker_host` and does **not** receive the turn-context map. Resume recurses through `continue_issue_turn` (`:528`) → `do_run_codex_turns`, replacing `issue` with `refreshed_issue`. `CodingAgent.start_session` is at `:348`. The session value already carries workspace/worker-host accessors (`session_workspace/1`, `session_worker_host/1`).
- `elixir/lib/aiur/orchestrator.ex:3526-3545` — `default_can_interrupt?/0`, `default_safe_checkpoints/0`, and `issue_tag/1` (the `agent:`-prefix label reader). Delivery-policy helpers run where the issue is in scope.
- `elixir/lib/aiur/event_humanizer.ex:14-23` — `adapter/0` → `humanize_method/2`. **Dead seam** (no live callers; verified during planning).
- `elixir/lib/aiur/issue.ex` — `Issue.label_names/1`; labels already populated on the struct.

### Institutional Learnings

- The dispatch seam is intentionally centralized in `Aiur.CodingAgent`; keep resolution **and** module/policy lookup there (the registry), rather than scattering either complexity parsing or backend `case` statements across callers.
- Sibling label namespaces (`priority:`, `complexity:`) each get their own anchored parser; reuse that shape for `model:`. Never widen `agent:` parsing.

---

## Key Technical Decisions

- **Backend registry as single source of truth (R7).** `Aiur.CodingAgent.backends/0` returns a map:
  `%{"codex" => %{adapter: Aiur.Codex.CodingAgent, transcript: Aiur.Codex.Transcript, can_interrupt: true, safe_checkpoints: [:notification, :tool_result]}, "claude" => %{adapter: Aiur.Claude.CodingAgent, transcript: Aiur.Claude.Transcript, can_interrupt: true, safe_checkpoints: [:notification]}}`.
  `known_backends/0` returns the map keys. `adapter/1`, `transcript_module/1`, `normalize_event/2`, and the orchestrator's delivery-policy helpers all look up this map and **raise/fail loud** on an unmapped key (no `_ -> Claude` catch-all). Config validation derives its allowlist from `known_backends/0`. Adding a backend = one entry. (Resolves the cross-persona P1: hardcoded two-backend assumption.)
- **Resolution precedence (R1, R8):** `backend_for(issue)` = `override_backend(issue)` (from a `model:<backend>` label, validated against `known_backends/0`; unknown value ignored + logged) `||` `routing_backend(issue)` (complexity level looked up in `agent.routing`) `||` `agent_kind()`. Returns a `"codex"|"claude"` (or future) **string**.
- **Routing table shape: `level → backend` (R3).** `agent.routing = %{4 => "claude", 5 => "claude"}`. Each level maps to exactly one backend, so collisions are structurally impossible at any number of backends (chosen over `backend → [levels]`, which permits two backends claiming the same level with undefined resolution). Validation: keys are positive integers, values ∈ `known_backends/0`.
- **Resolve once, store in the session, recover everywhere (R5).** The backend is resolved at `start_session` time and carried **in the session value** (alongside the existing workspace/worker-host the session already tracks). The initial path, `continue_issue_turn` resume recursion, and `run_queue_item_turn` all recover the backend **from the session**, never re-resolving. This gives true resolve-once: a `model:`/`complexity:` label edited mid-run (e.g. rework) cannot flip an in-flight session to a different backend, and operator/queue turns can't silently fall back to the global. (Resolves the two P1 findings on the resume/queue bypass and the resolve-once-vs-refreshed-issue tension.)
- **Backend threaded as a string, not a module.** The session stores the string; registry lookup yields modules at each dispatch site. Strings keep the session serializable and the registry the single place module identity lives. (Resolves the in-plan string-vs-module open question.)
- **Anchored complexity + override parsing.** `complexity_level/1` uses `~r/^complexity:(\d+)$/` (exact, anchored — no substring match on `complexity:5-spike`); multiple complexity labels ⇒ highest wins; unparseable/empty ⇒ `nil`. `override_backend/1` uses `~r/^model:(\w+)$/`; value must be in `known_backends/0` else ignored.
- **opencode: structure-for, don't-wire.** The registry contains only `codex` and `claude` (the two real `CodingAgent` adapters). `routing: {3 => "opencode"}` or `model:opencode` is rejected at config load (validation derives from `known_backends/0`) with a clear message, rather than silently dispatching to Claude. Promoting opencode later is one registry entry plus its adapter.

---

## Open Questions

### Resolved During Planning

- Where does resolution + dispatch live? → `Aiur.CodingAgent`: `backend_for/1` (resolution) + `backends/0` registry (dispatch/policy/validation source).
- Config shape? → `agent.routing` map, **level → backend**, validated in `Schema.Agent` against `known_backends/0`.
- Resolve once or per-site? → once at `start_session`, **stored in the session**, recovered (not re-resolved) on resume and queue turns.
- String vs module through state? → **string** in the session; registry resolves modules per site.
- Override tag namespace? → **`model:`** (own namespace; `agent:` is the state prefix and would corrupt `extract_state/2`).
- opencode? → structured-for in the registry, not wired; routing to it is a validation error for now.

### Resolved During Deepening (2026-05-30)

- **Session storage mechanism (was deferred).** The session is a plain `map()` built inside each adapter's `start_session` (`%{port:, metadata:, thread_id:, workspace:, worker_host:}`), and `session_workspace/1`/`session_worker_host/1` (`agent_runner.ex:1170-1174`) simply pattern-match keys. So the backend lives in the session map **without touching either adapter**: `AgentRunner` does `session = Map.put(session, :backend, backend)` immediately after `{:ok, session} = CodingAgent.start_session(...)`, and a `session_backend/1` accessor mirrors `session_worker_host/1`. The Codex/Claude adapters stay ignorant of their own backend label (correct — that's a routing concern, not an adapter concern).
- **Most dispatch wrappers resolve the adapter from the session itself (churn reduction).** Because the backend is now in the session map, `CodingAgent.run_turn/4`, `stop_session/1`, and `send_operator_message/2` can read `session[:backend]` and dispatch via the registry, falling back to `adapter()` when the key is absent (back-compat for any non-routed caller). Only `start_session/2` (no session yet — takes `backend:` opt) and `normalize_event/2` + `transcript_module/1` (operate on a raw event, not a session — take an explicit backend arg) need the backend passed explicitly. This shrinks U3's call-site churn to: the `start_session` wrapper, the `normalize_event`/`transcript_event_from` backend arg, and recovering `backend = session_backend(app_session)` at the message-handler construction sites.

### Deferred to Implementation

- Whether `complexity_level/1`/`override_backend/1` are private or `@doc false` public-for-test. Pick during U2; tests can also exercise them via `backend_for/1`.

---

## High-Level Technical Design

> *Directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```
# Aiur.CodingAgent

backends() :: %{
  "codex"  => %{adapter: Codex.CodingAgent,  transcript: Codex.Transcript,
                can_interrupt: true, safe_checkpoints: [:notification, :tool_result]},
  "claude" => %{adapter: Claude.CodingAgent, transcript: Claude.Transcript,
                can_interrupt: true, safe_checkpoints: [:notification]}
}
known_backends() :: Map.keys(backends())          # ["codex", "claude"]

backend_for(issue):
  override_backend(issue)                          # model:<backend> label, validated
    || routing_backend(issue)                      # complexity level -> Config.agent_routing()
    || Config.agent_kind()                          # fallback (back-compat)

adapter(backend)          -> fetch!(backends(), backend).adapter      # raises on unknown
transcript_module(backend)-> fetch!(backends(), backend).transcript   # raises on unknown
# adapter/0, transcript_module/0 kept: delegate through agent_kind() for display/non-issue callers

# AgentRunner
start_session: backend = CodingAgent.backend_for(issue)        # resolve ONCE
               {:ok, session} = CodingAgent.start_session(workspace, backend: backend, ...)
               session = Map.put(session, :backend, backend)    # store in the session map
# every turn (initial / resumed / queued) — RECOVER, never re-resolve:
               backend = session_backend(app_session)           # session[:backend]
               CodingAgent.run_turn(session, prompt, issue, ...) # reads session[:backend] internally
               normalize_event(msg, backend)                     # explicit (no session in scope)
               transcript_module(backend).extract(...)           # explicit

# Aiur.CodingAgent dispatch wrappers:
run_turn(session, ...)        -> adapter_for_session(session).run_turn(...)   # session[:backend] || agent_kind
stop_session(session)         -> adapter_for_session(session).stop_session(...)
send_operator_message(s, ...) -> adapter_for_session(s).send_operator_message(...)
start_session(ws, opts)       -> adapter(opts[:backend] || agent_kind()).start_session(...)

# Orchestrator (issue in scope):
default_can_interrupt?(issue)    -> backends()[backend_for(issue)].can_interrupt
default_safe_checkpoints(issue)  -> backends()[backend_for(issue)].safe_checkpoints
```

Routing decision matrix (this repo's seed `routing: {4 => claude, 5 => claude}`):

| Issue labels                       | Resolved backend           |
|------------------------------------|----------------------------|
| `model:claude` (any complexity)    | claude (override wins)     |
| `model:codex` (any complexity)     | codex (override wins)      |
| `complexity:4` / `complexity:5`    | claude                     |
| `complexity:1/2/3`                 | codex (fallback)           |
| (no complexity, no override)       | codex (= `agent.kind`)     |
| no `routing` cfg, no override      | `agent.kind` for all (back-compat) |
| `model:opencode` / `routing:{_=>opencode}` | rejected at config load (not a wired backend) |

---

## Implementation Units

- [ ] U1. **Config: `agent.routing` (level → backend) + accessor + registry-derived validation**

**Goal:** Add a schema-validated `agent.routing` field (level→backend) and `Config.agent_routing/0`, validating backend values against `Aiur.CodingAgent.known_backends/0`.

**Requirements:** R3, R4, R7

**Dependencies:** U2 (for `known_backends/0`) — implement the registry first, or stub `known_backends/0` and wire validation once U2 lands. Keep U1/U2 in one PR.

**Files:**
- Modify: `elixir/lib/aiur/config/schema.ex` — add `field(:routing, :map, default: %{})` to `Schema.Agent`; cast it; `normalize_routing/1` (string/atom keys → integer keys, values → strings); `validate_routing/1` (keys are positive integers, values ∈ `Aiur.CodingAgent.known_backends/0`).
- Modify: `elixir/lib/aiur/config.ex` — add `agent_routing/0` returning `settings!().agent.routing` (default `%{}`).
- Test: `elixir/test/aiur/workspace_and_config_test.exs`

**Approach:** Mirror `max_concurrent_agents_by_state` (`schema.ex:168,196,197`) — `field` + `cast` + normalize + a `validate_change` helper. The level domain is positive integers (no artificial `1..5` cap — operator-creatable `complexity:6+` labels must be routable; resolve the prior U1/U2 domain mismatch). Backend allowlist comes from the registry, never a re-typed literal.

**Patterns to follow:** `Schema.Agent.max_concurrent_agents_by_state` + `normalize_state_limits/1` + `validate_state_limits/2`.

**Test scenarios:**
- Happy: `agent.routing: {4: claude, 5: claude}` ⇒ `%{4 => "claude", 5 => "claude"}` via `Config.agent_routing/0`.
- Edge: missing `routing` ⇒ `%{}`.
- Error: `routing: {4: gpt}` (value not in `known_backends/0`) ⇒ config validation error.
- Error: `routing: {4: opencode}` (structured-for but unwired) ⇒ config validation error with a clear message.
- Error: non-integer key ⇒ validation error.
- Edge: `routing: {6: claude}` (level above this repo's current labels) ⇒ **accepted** (no artificial cap).

**Verification:** Seeded table parses; invalid backend values and non-integer keys rejected at load.

---

- [ ] U2. **Backend registry + `backend_for/1` + registry-driven dispatch**

**Goal:** Centralize module/policy identity in `backends/0`; add `known_backends/0`, `backend_for/1` (override → routing → fallback), and arity-1 `adapter/1`/`transcript_module/1`/`normalize_event/2` that look up the registry and fail loud on unknown.

**Requirements:** R1, R2, R4, R7, R8

**Dependencies:** None (U1 depends on this for `known_backends/0`)

**Files:**
- Modify: `elixir/lib/aiur/coding_agent.ex`
- Test: `elixir/test/aiur/coding_agent_test.exs`

**Approach:**
- Add `backends/0` (registry map: adapter, transcript, can_interrupt, safe_checkpoints per backend) and `known_backends/0` = `Map.keys(backends())`.
- `backend_for(%Issue{})`: `override_backend(issue) || routing_backend(issue) || Config.agent_kind()`.
  - `override_backend/1`: first `~r/^model:(\w+)$/` label whose captured value ∈ `known_backends/0`; else `nil` (unknown value logged, ignored).
  - `routing_backend/1`: `complexity_level(issue)` then `Map.get(Config.agent_routing(), level)`.
  - `complexity_level/1`: highest integer across `~r/^complexity:(\d+)$/` labels; `nil` if none/unparseable.
- `adapter/1`, `transcript_module/1`: look up `backends()`; raise a clear error on an unmapped backend (no silent `_ -> Claude`). Keep arity-0 `adapter/0`/`transcript_module/0` delegating through `agent_kind()` for display/non-issue callers (they pass `agent_kind()` into the arity-1 path).
- `normalize_event/2` takes a backend; keep `normalize_event/1` (delegates through `agent_kind()`) for any non-issue caller.
- **Session-aware dispatch wrappers:** `start_session/2` resolves `adapter(opts[:backend] || agent_kind())`; `run_turn/4`, `stop_session/1`, `send_operator_message/2` resolve the adapter from `session[:backend]` (a private `adapter_for_session/1` helper, falling back to `agent_kind()` when the key is absent). This is what lets AgentRunner thread the backend through the **session map** instead of every call site (see U3 + Resolved During Deepening).

**Patterns to follow:** `extract_priority`/`parse_priority_label` anchored-regex parser (`github/client.ex:467`); existing `adapter/0` case (`coding_agent.ex:24`) — now superseded by registry lookup.

**Test scenarios:**
- Override wins: issue `model:claude` + `complexity:1` ⇒ `"claude"`; `model:codex` + `complexity:5` ⇒ `"codex"`.
- Override unknown value: `model:gpt` ⇒ ignored, falls through to complexity/`agent_kind`.
- Complexity routing: `complexity:5` + `{4,5 => claude}` ⇒ `"claude"`; `adapter("claude")` ⇒ `Aiur.Claude.CodingAgent`; `transcript_module("claude")` ⇒ `Aiur.Claude.Transcript`.
- Complexity routing: `complexity:2` ⇒ `"codex"` ⇒ `Aiur.Codex.CodingAgent`.
- Fallback: no labels ⇒ `agent_kind` (assert both default-codex and configured-claude).
- Back-compat: empty routing + no override ⇒ always `agent_kind` (R4).
- Highest wins: `complexity:4` AND `complexity:2` ⇒ `"claude"`.
- Anchored parse: `complexity:5-spike` ⇒ no match; `complexity:` (empty) ⇒ `nil`; `complexity:05` ⇒ `5`; a non-complexity label containing the substring ⇒ no match.
- Fail loud: `adapter("opencode")`/`adapter("gpt")` ⇒ raises (not silent Claude).
- `known_backends/0` ⇒ `["codex", "claude"]` (order-insensitive).

**Verification:** Precedence correct across override/complexity/fallback; registry lookup returns correct modules and raises on unknown.

---

- [ ] U3. **Resolve once at session start; thread backend via the session through all turn paths**

**Goal:** Resolve the backend once when an issue's session starts, store it in the session value, and recover it (never re-resolve) on the initial, resumed, and operator-queue turn paths.

**Requirements:** R2, R5

**Dependencies:** U2

**Files:**
- Modify: `elixir/lib/aiur/agent_runner.ex` (and the session value carrier — likely the same module/struct that exposes `session_workspace/1`, `session_worker_host/1`)
- Test: `elixir/test/aiur/agent_runner_test.exs`

**Approach:**
- At `start_session` (`:348`), compute `backend = CodingAgent.backend_for(issue)` once; call `CodingAgent.start_session(workspace, backend: backend, worker_host: ...)`, then `session = Map.put(session, :backend, backend)`. Add `session_backend/1` (`%{backend: b} -> b; _ -> nil`) mirroring `session_worker_host/1` (`:1173`).
- Because the backend rides in the session map, `CodingAgent.run_turn/4`, `stop_session/1`, and `send_operator_message/2` resolve their adapter from `session[:backend]` (U2) — these call sites in AgentRunner need **no change**. Only the event/transcript path needs an explicit backend: recover `backend = session_backend(app_session)` and pass it to `normalize_event/2` and `transcript_event_from/3` (which gains a backend arg and calls `transcript_module(backend)`).
- The message handler is rebuilt at two sites (initial path and `run_queue_item_turn` `:645`); both have `app_session` in scope, so both recover `session_backend(app_session)` when constructing `codex_message_handler` (which gains a `backend` param/closure capture).
- **All three turn paths are covered for free** because they share the session value: initial (`do_run_codex_turns`), resume (`continue_issue_turn` `:528` → `do_run_codex_turns`, which keeps the same `app_session` while replacing `issue` with `refreshed_issue` — backend comes from the session, so no mid-run flip), and queue (`run_queue_item_turn` `:654`).

**Patterns to follow:** `session_workspace/1`, `session_worker_host/1` (`agent_runner.ex:1170-1174`), already recovered by `run_queue_item_turn`.

**Test scenarios:**
- Integration: `complexity:5` issue drives Claude adapter/transcript end-to-end.
- Integration: `complexity:1` issue drives Codex adapter/transcript.
- Resume invariant: an issue whose `complexity:`/`model:` label changes mid-run keeps its **original** session backend across a resumed turn (no flip).
- Queue path: an operator/queue-delivered turn uses the issue's resolved backend, not the global `agent.kind`.

**Verification:** A routed issue's session, initial turns, resumed turns, queued turns, normalization, and transcript all use its session-stored backend; grep confirms no per-issue path still reads `Config.agent_kind()` directly.

---

- [ ] U4. **Per-issue delivery policy in orchestrator (registry-driven)**

**Goal:** `default_can_interrupt?` and `default_safe_checkpoints` resolve from the issue's backend via the registry.

**Requirements:** R2, R7

**Dependencies:** U2

**Files:**
- Modify: `elixir/lib/aiur/orchestrator.ex`
- Test: `elixir/test/aiur/orchestrator_status_test.exs`

**Approach:**
- The two helpers (and their caller `default_running_control`) take the issue and read `backends()[CodingAgent.backend_for(issue)]`'s `can_interrupt` / `safe_checkpoints`. The per-agent control setup already has the issue in scope.
- No `_ -> default` catch-all: an unmapped backend raises via the registry lookup (consistent with U2), so a future backend can't silently inherit another's policy.

**Patterns to follow:** `issue_tag/1` (`orchestrator.ex:3545`); existing `default_safe_checkpoints/0` branches (`:3536`).

**Test scenarios:**
- `complexity:5` (claude) ⇒ `safe_checkpoints = [:notification]`; `complexity:2` (codex) ⇒ `[:notification, :tool_result]`.
- `can_interrupt` true for both codex- and claude-resolved issues.
- `model:claude` override on a `complexity:1` issue ⇒ claude policy.
- Unlabeled issue, default config ⇒ codex policy (back-compat).

**Verification:** Delivery-policy defaults differ correctly per resolved backend; registry is the only policy source.

---

- [ ] U5. **Verify and remove the dead EventHumanizer seam**

**Goal:** Confirm the `Aiur.EventHumanizer` dispatcher has no live caller and remove it (or, if a live caller is found, make it per-issue). This corrects origin R2's inclusion of the humanizer.

**Requirements:** R2-note

**Dependencies:** None

**Files:**
- Modify/Remove: `elixir/lib/aiur/event_humanizer.ex` (the `adapter/0` + `humanize_method/2` dispatcher)
- Test: adjust any test that referenced the dispatcher.

**Approach:**
- Planning verified: `event_humanizer.ex:23` (`Aiur.EventHumanizer.humanize_method/2`) has **zero** callers in `lib/`, `web/`, `test/`; `agent_log.ex:159` humanizes via its own private `humanize_event/1`; the per-backend `Codex.EventHumanizer`/`Claude.EventHumanizer` are not invoked through the seam either. Re-confirm with a grep, then **delete the dead dispatcher** rather than add a per-issue arity to dead code. The per-backend humanizer modules stay (they are referenced as behaviours / may be used elsewhere); only the unused dispatcher goes.
- If — contrary to the planning grep — a live caller exists, instead add `humanize_method/3` taking a backend and pass the resolved backend from that caller; keep `/2` for non-issue callers.

**Test scenarios:**
- After removal: `make all` green; no reference to `Aiur.EventHumanizer.humanize_method/2` remains.
- (If kept) same event humanized via codex vs claude backend produces each backend's phrasing.

**Verification:** No dead per-issue humanizer code is shipped; R2's humanizer claim reconciled (seam dead → removed).

---

- [ ] U6. **Seed WORKFLOW routing + docs**

**Goal:** Configure this repo (`4,5 → claude`) and document routing + the `model:` override.

**Requirements:** R3, R8

**Files:**
- Modify: `elixir/local-workflows/WORKFLOW.aiur.local.md` — add `agent.routing: {4: claude, 5: claude}` under the existing `agent:` block; **do not** change `agent.kind` (stays `codex`).
- Modify: `AGENTS.md` — short note: per-complexity routing via `agent.routing` (level→backend), the `model:claude`/`model:codex` per-issue override tags, and that backends derive from the `CodingAgent` registry (adding one is a registry entry).

**Approach:** Add the `routing` block; keep `kind: codex` as the fallback default. Document the `model:` override namespace and why it isn't `agent:`.

**Test scenarios:** None — config data + docs; behavior covered by U1–U4.

**Verification:** Running aiur on this repo routes `complexity:4/5` (and any `model:claude`) issues to Claude, the rest to Codex; `agent.kind` unchanged.

---

## System-Wide Impact

- **Interaction graph:** `AgentRunner` (agent process, transcript, normalize — backend from the session), `Orchestrator` (delivery policy), all resolve via the shared `CodingAgent.backends/0` registry + `backend_for/1`. The dead `EventHumanizer` dispatcher is removed.
- **Error propagation:** invalid `routing` config fails at load (changeset error, allowlist from `known_backends/0`); an unmapped backend at any dispatch site **raises** rather than silently defaulting — no split-brain, no quiet wrong backend.
- **State lifecycle:** backend resolved once at `start_session`, stored in the session, recovered on initial/resume/queue turns — fixed for the issue's whole run even if labels change mid-run.
- **API surface parity:** arity-0 `adapter/0`/`transcript_module/0`/`normalize_event/1` preserved for display + non-issue callers (delegating through `agent_kind()`); arity-1/2 added for per-issue sites.
- **Extensibility:** a new backend is one `backends/0` entry; validation, dispatch, and delivery policy follow automatically.
- **Unchanged invariants:** no `routing` + no `model:` tags ⇒ every site resolves to `agent.kind` exactly as today (R4); display badges unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| A turn path reads the global instead of the session backend ⇒ split-brain (operator/queue/resume turns mis-routed) | U3 covers all three `run_turn` paths (initial, `continue_issue_turn` resume, `run_queue_item_turn` queue) via `session_backend/1`. Grep `Config.agent_kind` after impl to confirm only display + arity-0-delegation sites remain. |
| A future/unmapped backend silently inherits Claude/codex behavior | Registry lookup **raises** on unknown at every dispatch + policy site; config validation rejects unknown backend values at load. No `_ -> default` catch-all anywhere on the per-issue path. |
| `model:`/`complexity:` label edited mid-run flips an in-flight session | Backend stored in the session at `start_session`; turns recover, never re-resolve. Resume invariant has an explicit test. |
| Override tag collides with `agent:` state namespace | Override uses the `model:` namespace with its own anchored parser; `agent:`/`extract_state` untouched. |
| ~~Pre-warm pool assumes one backend~~ (withdrawn) | Investigated during planning: `pre_warmed_sessions` warms **opencode chat panes** (`Aiur.Opencode.PrewarmSupervisor`), not codex/claude coding-agent sessions. Coding-agent backend is chosen per issue at `start_session`; there is no coding-agent pre-warm pool to mis-warm. Not a risk for this change. |
| Malformed/substring complexity labels | Anchored `~r/^complexity:(\d+)$/`; highest-wins; explicit edge tests in U2. |
| `complexity:N` labels may not exist in the tracker yet ⇒ feature inert until applied | Expected: unlabeled issues correctly fall back to `agent.kind` (R4). U6 docs the label scheme; operator applies labels. |

---

## Sources & References

- **Origin document:** `elixir/docs/brainstorms/2026-05-30-per-complexity-agent-routing-requirements.md`
- Related code: `elixir/lib/aiur/coding_agent.ex`, `elixir/lib/aiur/config/schema.ex`, `elixir/lib/aiur/config.ex`, `elixir/lib/aiur/agent_runner.ex`, `elixir/lib/aiur/orchestrator.ex`, `elixir/lib/aiur/github/client.ex`, `elixir/lib/aiur/event_humanizer.ex`
- Related issue: #215
- Doc-review (2026-05-30): 5 personas; folded findings — backend registry for extensibility (R7), `model:` override (R8), level→backend shape, resolve-in-session across all turn paths, dead-humanizer removal, pre-warm risk withdrawn, level-domain alignment, anchored label parsing.

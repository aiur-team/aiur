# Research spike — DeepSeek, Kimi, and OpenRouter as aiur backends

Status: **spike complete, awaiting operator sign-off before ticketing.**
Date: 2026-07-31. Prepared by the Executor for its-everdred.

Five operator nonnegotiables govern this work:

1. native opencode support;
2. direct conversation with agents via CLI, the opencode TUI, and the dashboard;
3. shared workspace — agents pick up each other's work and switch between backends;
4. seamless interop with any future backend;
5. dashboard usage/limit metering for every new provider.

---

## 1. Corrections to the operator's starting premises

- **DeepSeek V4-Flash is not API-only.** Weights are on Hugging Face under MIT
  (`deepseek-ai/DeepSeek-V4-Flash-0731`). The 0731 public-beta build shipped
  2026-07-31 — same model ID, retrained post-training, explicitly a push for
  agentic reliability.
- **Kimi K2 is discontinued** (2026-05-25). Current lineup is `kimi-k3`
  (flagship, 1M ctx) and `kimi-k2.7-code` / `-highspeed` (256K,
  coding-specialised, ~180 tok/s).
- **`aiur-claude` is not a per-backend requirement.** Its own `package.json`
  describes it as "a JSON-RPC 2.0 Claude Code App Server conforming to the
  OpenAI Codex app-server protocol spec" — a protocol shim, needed only
  because Claude Code does not speak aiur's app-server protocol. `codex` has no
  companion; `claude-repl` has none either.
- The source *does* exist locally, at
  `/home/everdred/github/everdred/claude-app-server` (not `~/github/`). An
  earlier review recorded it as missing; that was wrong.

## 2. The env-var shortcut is off the table

Repointing an existing backend at a new provider via `ANTHROPIC_BASE_URL` /
`OPENAI_BASE_URL`, or by swapping `agent.<backend>.command`, initially looked
like a config-only path. It fails four of the five nonnegotiables, and not
cosmetically:

- **NN4/NN5 break immediately.** `usage/headless/context.ex:49` maps agent
  families to provider atoms, so DeepSeek spend books against Claude's price
  table and Claude's rate-limit meters. Confidently wrong cost numbers are worse
  than absent ones.
- **NN3 becomes unexpressible.** Both providers share one registry key, so
  `switch_model_on_ratelimit` and `rate_limit_fallback` cannot tell them apart —
  aiur believes they are the same backend.
- **NN2 degrades unpredictably.** Delivery policy is keyed on registry
  capabilities; the impostor inherits `safe_checkpoints`/`can_interrupt` claims
  the real transport may not honour, producing hangs rather than clean errors.
- **NN1 mis-renders.** `Claude.Transcript.extract/2` applied to non-Claude event
  shapes falls through to `legacy_transcript_event`
  (`message_handler.ex:294-296`).

There is also a hard protocol blocker: both app-server backends speak JSON-RPC
over a port, not chat-completions. An OpenAI-compatible base URL satisfies
neither. **A distinct registry key and adapter is mandatory.**

## 3. What the nonnegotiables actually cost

The registry promise in `coding_agent/backend.ex:11-14` — "adding a backend must
require nothing else" — **holds for the runtime hot path and is false
everywhere else.** Execution is well-abstracted; config, metering, and
presentation are hardcoded to a `:codex | :claude` union across **54 files**.

| # | Nonnegotiable | Verdict | Cx |
|---|---|---|---|
| 1 | opencode native | **satisfied-free** | 1 |
| 2 | CLI + TUI + dashboard | **satisfied-free** | 2 |
| 3 | shared workspace | **free at file level** | 0 |
| 3 | cross-backend switching | needs de-hardcoding | 3 |
| 3 | conversation continuity | **does not exist** | 5 |
| 4 | future-backend interop | config + metering tax | 4 |
| 5 | usage metering | provider union + semantics | 3 |

**NN1 — free.** There are **zero** per-backend branches in all of
`src/lib/aiur/opencode/`. Backend variance collapses once upstream at
`message_handler.ex:293` via `transcript_module(backend).extract/2`. Implement
`Transcript.extract/2`, point the registry entry at it, and opencode display
works entirely. opencode is confirmed to be aiur *serving* an OpenAI-compatible
endpoint **to** the TUI (`opencode/chat_completions.ex:39-53`), not a consumer
backend.

**NN2 — free, with a real contract to honour.** CLI
(`agent_control_cli.ex:389-429`), TUI
(`opencode/chat_completions/operator_dispatch.ex:16-50`), and dashboard
(`dashboard_live.ex:430-451`) all funnel through `AgentChat.send/3`. Policy
resolution (`operator_messages/delivery_policy.ex:9-47`) is registry-driven and
never reads a backend name — **the dashboard works for all backends today.** The
per-backend work is the safe-checkpoint contract: a backend with
`safe_checkpoints: []` and no `immediate_delivery` will silently never drain
queued operator messages.

**NN3 — the decision that sizes the whole effort.** Two readings:

- *File level* — workspace, branch, workpad. **Works today.** All of
  `src/lib/aiur/workspace/` is backend-agnostic; the only backend reference is a
  marker filename.
- *Conversation level* — reasoning context. **No transcript handoff exists
  anywhere.** `SessionHandle.load/3` pattern-matches the backend
  (`session_handle.ex:104`), so a Codex handle is structurally unloadable by any
  other backend. Every cross-backend switch is a cold start, and
  `prior_work_continuation` defaults to `false`
  (`config/schema/agent.ex:87`), so out of the box the new agent does not even
  receive the "resume from workspace state" prompt.

Mid-ticket switching is additionally hardcoded: `rate_limit_fallback.ex:31-32`
declares `@primary_backend "codex"` / `@fallback_backend "claude"`, and the
config validator **rejects any other value** (`config/schema/agent.ex:220-223`).
"Fall back to DeepSeek when Codex rate-limits" is a code change, not config.

**NN4 — the unbudgeted tax.** Config is the surprise: per-backend settings are
Ecto embedded schemas (`config/schema/agent.ex:149-150`), so a new backend needs
a new embed and changeset. Also `inferred_agent_kind/1` (`config.ex:743-749`),
`agent_executable/1` (`init/agent_cli.ex:209-214`), and the init wizard.
Metering spans ~15 further files beyond the four already known.

## 4. Provider facts

| | DeepSeek V4-Flash | Kimi K2.7-Code | Claude Sonnet 5 | Claude Opus 5 |
|---|---|---|---|---|
| Input /1M | **$0.14** | $0.95 | $2.00 | $5.00 |
| Cache hit /1M | **$0.0028** | ~$0.19 | $0.20 | $0.50 |
| Output /1M | **$0.28** | $4.00 | $10.00 | $25.00 |
| Rate-limit headers | **none documented** | **`X-RateLimit-*`** | yes | yes |
| Limit model | prepaid + 2500 concurrent | RPM/TPM/TPD tiers | subscription window | subscription window |

V4-Flash output is **89x cheaper than Opus**, and its cache hit is 71x better
than Claude's *and automatic* — no `cache_control` breakpoint management. For a
fleet re-sending a large stable system prompt every turn, the cache economics
dominate the sticker price. Anthropic's tokenizer also emits ~30% more tokens
for the same text, widening the real delta.

Known DeepSeek harness hazards, both live in the multi-turn tool loop aiur runs:
assistant `reasoning_content` must be echoed back in later turns or the API
returns 400; and tool calls are intermittently emitted as plain text with
`finish_reason: "stop"` and `tool_calls: null`. Routing DeepSeek through the
Responses API (0731 is explicitly Codex-adapted) sidesteps the first.

No equivalent compatibility bug reports were found for Kimi.

## 5. OpenRouter — add it, as a third role

The operator's argument is adoption, and it is the strongest case for it: one
key instead of five materially changes who can run aiur. That is a different job
from fleet routing, and both can be true.

| Role | Route | Why |
|---|---|---|
| Volume workhorse | native DeepSeek | 50x automatic cache hits; the economics only exist natively |
| Header-paced work | native Kimi | returns `X-RateLimit-*`, which the pacer reads |
| Breadth + easy install | OpenRouter | one key, every other model, no per-provider signup |

OpenRouter passes provider token rates through without markup (5.5% on credit
purchases; BYOK free for the first 1M requests/month, then 5%). What it costs
is precisely what this fleet depends on: **rate-limit visibility** (you pace off
a proxy's aggregate limits, not the provider's per-key quota) and **cache
determinism** (no guaranteed prefix stickiness across routing, which silently
turns DeepSeek's $0.0028 back into $0.14 — a 50x swing with no signal).

BYOK narrows both gaps and is the recommended default for anyone routing
significant volume through it.

Two requirements if OpenRouter lands:

- **Per-model attribution.** If OpenRouter is a single provider atom, a fleet
  running four models through it reports as one meter and pacing goes blind.
- **Cache-hit visibility.** OpenRouter reports cache data in the `usage`
  payload rather than headers; if `PriceTable` cannot see a cache hit, cost
  reporting overstates by up to 50x on DeepSeek with no indication.

## 6. NN5 — metering, and why the ground is unstable

The dashboard's current question is "how much of my allowance is left." That
assumes a renewing subscription quota. It does not map uniformly:

| Provider | Honest "am I running low?" |
|---|---|
| Claude / Codex | % of a 5h/weekly allotment consumed |
| Kimi | throughput headroom now (`X-RateLimit-*`) |
| DeepSeek | **dollars of prepaid credit left**; concurrency headroom, not tokens |
| OpenRouter | dollars of prepaid credit left |

A unified meter must therefore be honest about *which* question it is answering
per provider, and must not fabricate a percentage for providers that expose no
allotment. This is a product-design decision, not just plumbing.

Two open bugs sit in exactly this layer and should be fixed **before** adding
providers:

- **#1406** — `ProviderMeterProbe`'s workspace is never created, so usage
  probing fails every cycle. The Codex probe has been silently dead.
- **#1436** — the Claude segment renders a confident "0% used" when
  `used_percent` is absent, which reads as headroom when the truth is unknown.

**Unverified, and it changes the pacing design:** whether DeepSeek returns any
undocumented rate-limit headers, and the exact shape of its balance endpoint. A
single `curl -i` against a live key settles it. The research agent covering this
hit a provider usage limit before completing.

## 7. Recommendation

Split into three tickets, sequenced.

**A — De-hardcode the provider union (prerequisite).** Make config, metering,
and presentation registry-driven; fix #1406 and #1436 first. Without this every
future provider pays the same tax, and NN4 is not satisfiable by construction.

**B — Generic OpenAI-compatible backend, with three registered instances.** One
adapter parameterised by `base_url`, key, and model list; DeepSeek, Kimi, and
OpenRouter become config instances rather than three integrations. Land Kimi
first — its `/anthropic` endpoint is a deliberate Claude Code drop-in and it
returns the rate-limit headers the pacer already reads, so it proves the path
end-to-end. Then DeepSeek as the volume workhorse, budgeting real time for the
two documented tool-loop defects.

**C — Cross-backend conversation continuity (epic, only if required).** A new
subsystem for transcript replay or summarisation across backends. Not needed if
"pick up each other's work" means the workspace and branch, which works today.

**Operator decision required before ticketing:** does NN3 mean file-level
handoff (tractable, works now) or conversation-level continuity (an epic)? That
single answer changes the shape of everything downstream.

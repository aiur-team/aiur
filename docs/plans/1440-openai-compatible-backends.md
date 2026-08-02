# Plan — Generic OpenAI-compatible coding-agent backend

Issue: #1440 (complexity:5). Base: `develop`. Prerequisite #1439 is merged.
Research source: `docs/research/multi-provider-backends.md` on
`origin/executor-handoff`.

## Goal

Add one direct HTTP coding-agent adapter and register three independently
configurable instances: `kimi`, `deepseek`, and `openrouter`. Each instance must
complete the same backend lifecycle as Codex/Claude, render only through the
normalized transcript boundary, drain queued Executor messages at declared safe
checkpoints, and attribute usage and account meters without inventing missing
data.

Cross-backend pickup is workspace-only and cold. The new backends are deliberately
non-resumable; continuation prompting supplies workspace context after a switch.
No transcript or provider conversation is transferred.

## Decisions fixed for implementation

- `Aiur.OpenAICompat.CodingAgent` is the sole implementation of the five backend
  callbacks. Registry capabilities and per-instance config select endpoints,
  model defaults, API-key environment variables, transport dialect, and quirks.
- The backend owns conversation state in a session process. `AgentRunner` retains
  the original session map across turns, so immutable history in returned maps
  would be lost.
- Kimi and OpenRouter use Chat Completions. DeepSeek prefers Responses, with a
  configurable Chat Completions fallback dialect for deployments that require it.
- Both Kimi and DeepSeek retain `reasoning_content` in assistant messages during
  multi-step tool loops. DeepSeek additionally enables a conservative plain-text
  tool-call parser: only explicit structured envelopes are accepted, and every
  tool name/argument payload is validated before dispatch.
- The adapter declares `can_interrupt: false`,
  `safe_checkpoints: [:notification, :tool_result]`, and request-only control
  confirmation. It invokes the existing safe-checkpoint callback after provider
  responses and tool results, which lets the shared CLI/TUI/dashboard queue drain
  without backend-specific messaging branches.
- `openai_compat` is an honest provider-account-generation and meter backend type;
  it is not reported as an app-server connection.
- Command execution is fail-closed. The tool surface exposes workspace-scoped file
  operations and a command tool only through an explicit sandbox runner. On Linux
  the first implementation uses bubblewrap; if the sandbox is absent, command
  execution returns an unavailable result rather than running provider-authored
  shell on the daemon host.
- OpenRouter attribution uses the response's actual model plus router metadata for
  the selected upstream provider. Cache reads come from the response usage body,
  never rate-limit headers.
- Missing or unauthorised balance/credit/rate-limit observations remain unknown.
  The dashboard must never turn absence into a confident zero-percent meter.

## Implementation units

### U1 — Transport, session process, tool loop, transcript, checkpoints

Create the `Aiur.OpenAICompat` boundary:

- a configuration resolver that merges registry instance defaults with the
  provider config block without ever logging credential values;
- Req transports for Chat Completions and Responses with injectable request
  functions for deterministic fake-server tests;
- a session process retaining messages, request identifiers, and local in-flight
  state across turns;
- validated tool definitions and results for workspace file operations, sandboxed
  command execution, and the existing Aiur dynamic-tool executor supplied by the
  runner;
- normalized assistant/reasoning/tool-call/tool-result/usage events;
- `Transcript.extract/2` mappings into the shared `TranscriptEvent` shape;
- safe-checkpoint delivery and pause checks between network/tool boundaries.

Proof first: add fake-server tests for a complete multi-tool turn, reasoning replay,
tool-argument rejection, text-fallback rejection/acceptance, a queued operator
message delivered at a checkpoint, provider errors, and secret redaction.

### U2 — Registry instances and configuration

Register `kimi`, `deepseek`, and `openrouter` as instances of the same adapter.
Each registry entry owns:

- base URL, endpoint dialect, API-key env name, models, quirk flags, capabilities,
  presentation descriptor, pricing policy, usage adapter, meter probe, and trusted
  account-generation source;
- Kimi defaults to `https://api.moonshot.ai/v1` and `kimi-k2.7-code`;
- DeepSeek defaults to `https://api.deepseek.com`, `deepseek-v4-flash`, and the
  Responses dialect;
- OpenRouter defaults to `https://openrouter.ai/api/v1` and requires an explicit
  model because its catalog is dynamic.

The config schema remains registry-driven. Add a generic config block rather than
new per-provider Ecto modules or provider unions. Regression tests must prove the
new instances route through registry accessors only.

### U3 — Usage attribution and pricing

Add one normalized usage adapter that consumes transport events for all three
families. Preserve requested and resolved model separately. For OpenRouter, set
the resolved model and upstream provider from response metadata; retain cache-read
tokens from the usage payload.

Add price-table rows with `effective_date`, `source_url`, and
`source_reviewed_at`. Cover Kimi K2.7 code, DeepSeek V4 Flash cache miss/hit/output,
and explicitly supported OpenRouter model rows. Unknown OpenRouter models remain
unpriced rather than borrowing the router's name as a model price.

### U4 — Account generations, meters, and dashboard semantics

Generalize backend types to registry-declared account-generation scopes and bind
API-key-backed sessions to `:openai_compat` generations without retaining secrets.

- Kimi: ingest throughput headroom from documented response-header names when
  present; absence remains unknown.
- DeepSeek: probe `GET /user/balance`, report USD prepaid balance when present, and
  expose local observed concurrency against the 2,500 cap with an honest label.
- OpenRouter: probe credits using the configured management credential; report
  total credits minus total usage. An ordinary inference key that cannot access
  the endpoint produces an unavailable meter, not zero credits.

Extend existing provider-meter presenters only where a genuinely new unit/label is
required; provider identity and ordering continue to come from the registry.

### U5 — Cold continuation default and integration regression

Flip `prior_work_continuation` to default true, retain an explicit false override,
and verify a non-resumable backend receives the continuation prompt when taking
over a workspace created by another backend. Do not copy a thread id or transcript.

### U6 — Verification and shipping

Run the repository-scoped gate:

- `mix compile --warnings-as-errors`;
- `mix format`;
- `mix aiur.affected_tests`, followed by every emitted test command with
  `mix test --max-cases 4`;
- focused fake-server/integration tests for each provider dialect;
- the #1439 no-hardcoded-provider-union regression guard.

Then simplify the cross-provider code, run `ce-code-review` against `develop`, fix
all actionable findings, commit/push, and open a draft PR against `develop`.

## Acceptance boundary and unavailable live evidence

This workspace has no Moonshot, DeepSeek, or OpenRouter credential configured, so
live endpoint turns and the unresolved DeepSeek header probe cannot be performed
here. Agent workspaces are also explicitly forbidden from launching the real
`scripts/aiurdev --test` TUI. The implementation therefore supplies fake-server
end-to-end coverage and focused local gates, while the PR handoff must call out the
remaining Executor-root acceptance run with real keys:

1. one real ticket per instance through tool calls and PR push;
2. an operator message sent through CLI, TUI, and dashboard and visibly drained;
3. a Codex-started workspace cold-picked-up by DeepSeek;
4. honest dashboard meters observed for authenticated accounts;
5. DeepSeek `curl -i` header observation recorded without exposing credentials.

No claim of full manual verification is permitted until that Executor-root run is
captured from the rendered TUI.

## Non-goals

- Cross-backend conversation continuity.
- Self-hosted model serving or model weights.
- OpenRouter as default fleet routing.
- A provider-specific branch in opencode, AgentChat, dashboard messaging, config
  validation, pricing validation, or account-generation validation.

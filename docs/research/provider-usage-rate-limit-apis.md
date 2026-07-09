# Research Brief: OpenAI/Anthropic Usage, Cost & Rate-Limit APIs for Rate-Limit-Aware Orchestration

_Part of the `research/optimization-pillars` wave. Maps to Pillar 6 (usage/rate-limit reconciliation) and Roadmap Phase 6 (rate-limit-aware scheduling)._

**Research value: high** — both providers publish concrete real-time headers and Admin usage/cost APIs with clear semantics; the highest-leverage finding is a gap specific to Aiur's architecture (CLI-wrapped agents vs. raw API calls), which materially changes what's actually implementable.

## 1. OpenAI signals table

| Signal | Where it appears | Granularity | Notes |
|---|---|---|---|
| `x-ratelimit-limit-requests` / `-tokens` | Every API response header | Per org/project, per model | Max permitted before exhaustion |
| `x-ratelimit-remaining-requests` / `-tokens` | Every API response header | Live | Headroom before 429 |
| `x-ratelimit-reset-requests` / `-tokens` | Every API response header | Live | Time-to-reset (duration, not timestamp) |
| `x-ratelimit-limit/remaining/reset-project-tokens` | Response header | Project-scoped | Separate pool from org-level |
| `retry-after-ms` | On 429 | Live | Explicit wait hint |
| `usage.input_tokens` / `output_tokens` / `total_tokens` | Responses API response body | Per-call | Includes `input_tokens_details`/`output_tokens_details` (cached, reasoning) |
| Usage tiers (Free/1–5) | Account-level, spend-gated | Static | Tier 5 = $200k/mo cap, auto-promotes on cumulative spend |
| Usage API `/v1/organization/usage/completions` | Admin API | 1m/1h/1d buckets | `group_by` model/project/user/api_key/batch |
| Costs API `/v1/organization/costs` | Admin API | 1d only | USD, grouped by project_id/line_item/api_key_id |
| Codex CLI `usageLimitExceeded` + `/status` | CLI text output only | 5h rolling + 7d rolling credit windows | **Not** the same mechanism as HTTP headers above — see §6 |

Known reliability gotcha: users and Azure/OpenAI community threads report `x-ratelimit-*` sometimes returning `-1`/`0` sentinel values on the Responses API — treat headers as advisory, not authoritative, and keep exponential backoff+jitter as the fallback regardless of header state ([community.openai.com](https://community.openai.com/t/openai-response-x-ratelimit-header-values-1-and-0/1366625)).

## 2. Anthropic signals table

| Signal | Where it appears | Granularity | Notes |
|---|---|---|---|
| `anthropic-ratelimit-requests-limit/remaining/reset` | Every Messages API response | RPM, token-bucket (continuous refill, not fixed windows) | `reset` is RFC 3339 timestamp |
| `anthropic-ratelimit-tokens-*` | Every response | Combined bucket | Reflects **most restrictive** current constraint (org or workspace) |
| `anthropic-ratelimit-input-tokens-*` / `-output-tokens-*` | Every response | Separate ITPM/OTPM | `input_tokens` counts only post-cache-breakpoint tokens; `cache_read_input_tokens` does **not** count toward ITPM (except Haiku 3.5) |
| `anthropic-priority-*-tokens-*` | Priority Tier only | Separate pool | Distinct capacity from standard tier |
| `retry-after` | On 429 | Seconds | |
| Usage tiers: Start/Build/Scale/Custom | Org-level | Static, auto-promotes | Spend caps: Start $500/mo, Build $1,000/mo, Scale $200,000/mo |
| Usage API `/v1/organizations/usage_report/messages` | Admin API | 1m (max 1440 buckets)/1h (168)/1d (31) | `group_by` model/workspace/api_key/service_tier/speed/inference_geo |
| Cost API `/v1/organizations/cost_report` | Admin API | 1d only | USD cents, grouped by workspace_id/description |
| Claude Code `/usage` | CLI, interactive only | Session estimate | Explicitly **not** authoritative billing; doesn't work with `--print` |

Confirmed data-freshness SLA: Anthropic's docs state usage/cost data appears "typically within 5 minutes," polling supported at 1/min sustained ([platform.claude.com](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)). OpenAI's Admin API docs don't publish an equivalent explicit SLA in the cookbook.

## 3. What's real-time vs. reconciled

| | Real-time (per-call) | Reconciled (Admin API) |
|---|---|---|
| **OpenAI** | `x-ratelimit-*` headers (org/project scoped, current window only) + `usage` body field per response | `/v1/organization/usage/completions`, `/v1/organization/costs` — accurate but not instant, no published SLA found; community reports suggest similar few-minute lag to Anthropic |
| **Anthropic** | `anthropic-ratelimit-*` headers, token-bucket continuous refill | `/v1/organizations/usage_report/messages`, `/v1/organizations/cost_report` — ~5 min lag, authoritative for billing |
| **Codex CLI (subscription)** | None via HTTP — only CLI text (`usageLimitExceeded`, `/status` %) | `platform.openai.com/usage` — explicitly does **not** reflect live 5-hour position (5-min lag) |
| **Claude Code CLI (subscription)** | **None exposed to scripts today** — confirmed via GitHub issue #55333 (closed, dup): headers are received internally but not persisted to any file hooks/statuslines can read; `/usage` is interactive-only | Admin/Enterprise Analytics API (org-level, not per-CLI-session) |

**Critical architectural finding:** if Aiur drives Codex/Claude via their CLIs/app-servers (as its tmux/send-keys pattern suggests) rather than calling the raw HTTP APIs directly, the rich per-call headers described in §1/§2 are **not accessible** through the CLI surface. Real-time throttling signal from CLI-wrapped agents is currently limited to parsing text (`usageLimitExceeded`, "try again in Xh Ym", `/status` percentages) — a text-scraping problem, not a header-reading problem — unless Aiur separately authenticates a raw API key for a side-channel probe.

## 4. Recommended scheduling design (Elixir orchestrator)

Two-layer design, mirroring the "AIMD for concurrency + token bucket for known caps" composition pattern used in Netflix's `concurrency-limits` ([github.com/Netflix/concurrency-limits](https://github.com/Netflix/concurrency-limits)):

1. **Per-provider GenServer limiter** (one per {provider, model-class, credential}) built on `ExRated`/`Hammer` token-bucket semantics ([hexdocs.pm/ex_rated](https://hexdocs.pm/ex_rated/ExRated.html)) — tracks RPM/ITPM/OTPM against the *last known* header values. ETS-backed, atomic via GenServer state, cheap to query before dispatch.
2. **AIMD concurrency envelope on top** — start with a conservative max-concurrent-agents-per-provider; additively increase after N consecutive clean turns, multiplicatively cut on any 429 or `usageLimitExceeded`. This absorbs the fact that Codex/Claude Code text signals are laggy/text-based and can't be trusted to the minute.
3. **Signal ingestion, by surface**:
   - Raw-API paths (if any direct API keys are used): parse `x-ratelimit-*` / `anthropic-ratelimit-*` after every call, feed into the GenServer bucket state directly — this is the only truly real-time signal.
   - CLI-wrapped paths (Codex CLI, Claude Code): treat as text-event triggers only — regex for `usageLimitExceeded` / rate-limit strings, extract reset duration, and force that provider's AIMD envelope to near-zero until reset. Do not attempt to infer RPM/TPM headroom from CLI output; there is none.
4. **Reconciliation loop**: separate low-frequency (1/min, per Anthropic's stated polling ceiling) poller against both Admin APIs (`usage_report/messages` + `/v1/organization/usage/completions`), written to the dashboard's cost/usage store. This is for the historical dashboard, not for throttling decisions — the ~5 min lag makes it useless as a real-time control signal, but it's the only authoritative source for reconciling against actual billing.
5. **Backpressure at dispatch, not mid-turn**: gate *new* agent dispatch on bucket/AIMD state; let in-flight turns finish (both Codex and Claude Code CLIs report they generally let an active turn complete even after the limit trips), matching Aiur's existing turn-respecting supervision model.

> **Aiur-specific corroboration:** during this very run, the operator observed Codex `usageLimitExceeded` with a **multi-hour reset ("try again at 6:23 AM")** and, separately, that the Claude fallback was only text/CLI-driven. That matches this brief exactly: the practical control signal Aiur has today is text-event-based, and the AIMD-envelope + reroute-to-other-backend approach is the right shape.

## 5. Auth/secrets considerations

- Admin API keys (`sk-ant-admin01-...` for Anthropic; separate Admin key for OpenAI) are **distinct credential types** from standard API keys — least-privilege: only the reconciliation poller process needs the Admin key; per-agent dispatch processes should never hold it.
- Anthropic Admin API is unavailable for individual accounts — requires an actual Console organization; Claude Enterprise orgs use a *different* key type (Analytics API key) with different endpoints entirely — confirm which Anthropic plan Aiur's org is on before building against the wrong API.
- OpenAI Admin key auth is a plain `Authorization: Bearer` header — same exposure risk as any other secret; scope via project_ids filters if multiple projects share one org.
- CLI-based agents (Codex/Claude Code) authenticate via their own OAuth/subscription session, separate entirely from any API keys used for the Admin/reconciliation side-channel — two separate credential sets to manage per provider if both signal paths are pursued.

## 6. Risks/gotchas

- **OpenAI header unreliability**: community-reported `-1`/`0` sentinel values on Responses API headers; don't trust headers as sole gate, keep backoff+jitter as fallback.
- **Claude Code CLI has no scriptable real-time signal today** (confirmed via closed/duplicate issue #55333) — any design assuming per-turn header access from the CLI wrapper needs a fallback text-parsing plan.
- **Codex credit model is intensity-based, not message-count-based** — reasoning-heavy turns burn 5h/weekly budget faster than turn count suggests; can't predict remaining capacity from request counts alone.
- **Two independent Codex windows (5h + 7d) can drain independently** — a burst can exhaust the 5h window while weekly is fine, or steady moderate use can exhaust weekly while 5h windows individually look healthy. Track both.
- **Anthropic ITPM cache accounting**: `input_tokens` header/body field excludes cached tokens for most models — naive token accounting will overestimate ITPM consumption; must add `cache_creation_input_tokens` + `cache_read_input_tokens` correctly per the model-specific rule (Haiku 3.5 is the exception).
- **Batch APIs have separate limit pools** (both providers) — don't conflate with interactive Messages/Responses limits when building a unified scheduler.
- **Anthropic "acceleration limits"**: sharp usage ramp-ups can trigger 429s even under nominal RPM/TPM — ramp concurrency gradually rather than jumping straight to max-agents. _(Aiur has already hit this empirically — phase-launch bursts of 5+ simultaneous agents.)_
- **Admin API lag (~5 min) makes it unusable as a throttle signal** — only valid for dashboard/reconciliation, never for live scheduling decisions.

## 7. v1 cutline

**Ship now:**
- Per-provider AIMD concurrency envelope keyed on text-parsed `usageLimitExceeded`/429 events (works for both CLI-wrapped agents today, no new auth needed). _This formalizes Aiur's current manual "reroute to the other backend on usage limit" policy into an automatic scheduler input._
- Nightly/hourly reconciliation poller against both Admin usage/cost endpoints for the dashboard (needs one Admin key per provider, isolated to that process).

**Defer:**
- Direct header-level throttling (`x-ratelimit-*`/`anthropic-ratelimit-*`) — only worth building if/when Aiur adds a raw-API dispatch path alongside the CLI wrappers; not accessible through Codex CLI or Claude Code CLI as currently shipped.
- Priority Tier / fast-mode separate-pool tracking — irrelevant until Aiur actually opts into those tiers.
- Per-workspace/per-API-key granular cost attribution in the dashboard — start with org-level daily buckets, add grouping dimensions later.

## Sources
- [Rate limits — Claude Platform Docs](https://platform.claude.com/docs/en/api/rate-limits) — full `anthropic-ratelimit-*` header table, tier limits, cache-aware ITPM rules
- [Usage and Cost API — Claude Platform Docs](https://platform.claude.com/docs/en/manage-claude/usage-cost-api) — endpoints, bucketing limits, 5-min freshness SLA, 1/min polling guidance
- [Rate limits | OpenAI API](https://developers.openai.com/api/docs/guides/rate-limits) — `x-ratelimit-*` header definitions, usage tiers
- [OpenAI Usage/Costs API cookbook](https://developers.openai.com/cookbook/examples/completions_usage_api) — endpoint paths, query params, response shape
- [OpenAI community: x-ratelimit header values -1 and 0](https://community.openai.com/t/openai-response-x-ratelimit-header-values-1-and-0/1366625) — header reliability gotcha
- [Codex CLI Usage & Rate Limits (inventivehq.com)](https://inventivehq.com/blog/codex-cli-usage-rate-limits) — 5h vs weekly window mechanics, credit-based depletion
- [Persist anthropic-ratelimit-unified-5h-* headers for hooks/statuslines — GitHub issue #55333](https://github.com/anthropics/claude-code/issues/55333) — confirms Claude Code CLI does not expose headers to scripts today
- [Netflix/concurrency-limits](https://github.com/Netflix/concurrency-limits) — AIMD algorithm, client/server concurrency-limit composition pattern
- [ExRated (hexdocs.pm)](https://hexdocs.pm/ex_rated/ExRated.html) — Elixir GenServer/ETS token-bucket implementation

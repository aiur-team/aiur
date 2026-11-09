---
title: Policy-driven provider and capacity choice - Plan
type: feat
date: 2026-11-08
issue: 7881
execution: code
---

# Policy-driven provider and capacity choice - Plan

Issue #7881. Base: `origin/main` at `1221fcb94a`. Related: #7879 (402 does not fall through), #7504 (usage
floor), #5693 (per-ticket spend cap), #7662 (config provenance).

## Read this first

- **What changes.** Provider choice for coding workers becomes a *policy* evaluated over the routes Aiur already
  computes. The policy adds four things today's chain lacks: a Claude reserve kept for Executors, a last-resort
  class, billing class (subscription, prepaid, metered), and hard spend limits.
- **What stays.** `agent.priority` and `agent.routing` keep ordering routes, and headroom keeps choosing the
  account. With no `capacity` config the policy allows every route and dispatch behaves exactly as today.
- **Where it lives.** One pure decision module, called from the route filter that already hosts the usage floor
  (`Aiur.CodingAgent.UsageFloorGate`). It is not a second scheduler.
- **Executors are not dispatched.** Aiur detects the Executor's harness from its environment
  (`src/lib/aiur/executor/harness_session.ex:21-27`); it never picks the Executor's provider. "Keep Claude for
  Executors" therefore means: workers stop spending a Claude account before it falls below a reserve.
- **Unknown stays unknown.** Today an unknown or stale reading allows dispatch everywhere
  (`src/lib/aiur/accounts/usage_floor.ex:23-30`). Under the policy, unknown still allows ordinary routes, but it
  never counts as headroom on a reserved account or under a hard limit. Those fail closed.

## 1. Integration point

### Today

| Step | Code | What it decides |
|---|---|---|
| Route list | `Routing.select_for_dispatch/2`, `routing.ex:35-60`; `eligible_routes/1`, `:69-74` | Complexity routes, else `agent.priority`; drops unknown backends, missing credentials, peak pricing |
| Fleet hold | `DispatchPolicy.Gates.provider_gate/2`, `orchestrator/dispatch_policy/gates.ex:178-193` | Holds all dispatch only when every backend is limited in `model-usage.json` |
| Availability | `ModelAvailability.available?`, read at `headroom_dispatch.ex:347`, `floor_chain.ex:40,87` | Ledger `limited` flag and backoff |
| Usage floor | `UsageFloorGate.split_candidates`, `headroom_dispatch.ex:164` | Skips a route at or below `agent.usage_floor_percent` remaining |
| Account | `HeadroomDispatch.select`, `:206-218`; else `FloorChain.chain/4`, `:51-60` | First backend in priority with a non-exhausted candidate, most headroom wins |
| Running claim | `RateLimitFallback`, `orchestrator/rate_limit_fallback.ex:39,74` | Moves a running primary to one configured fallback |
| Paused claim | `PausedFallback`, `rate_limit_fallback/paused_fallback.ex:7,29-35,51-55` | After 600 s, moves only primary-backend claims to one fallback |

### Proposed

A new pure module `Aiur.Capacity.Policy` takes the expanded candidates (route x account), their readings, the
reservation ledger (section 4) and the effective `capacity` config, and returns one verdict per candidate:

- `:allow`
- `{:hold, reason}`: the candidate may not take this work now
- `{:defer, :last_resort}`: allowed only if no other candidate is allowed

It is applied in one place: the candidate split that `UsageFloorGate.split_candidates` already performs for
headroom, and its equivalent in `FloorChain` for `priority` and `balance` selection. The floor becomes one rule
inside the policy instead of a sibling gate. Ordering among allowed candidates is unchanged: priority first,
then headroom.

Rules, in evaluation order:

1. **Hard limits.** A metered or prepaid source whose daily, weekly or monthly limit is reached, or whose spend
   is unknown while a limit is set, is held. Pins (`model:` labels, a fallback's selected backend) obey this rule.
2. **Reserve.** A reserved account whose projected remaining (section 4) is at or below its reserve is held for
   worker dispatch. An unknown or stale reading on a reserved account is held. Pins obey this rule too: a pin
   chooses the backend, and when every account on it is reserved the ticket waits.
3. **Floor.** Today's `usage_floor_percent` rule, unchanged.
4. **Last resort.** A `last_resort: true` source is deferred while any non-last-resort candidate is allowed.
5. **Capability.** A source may declare `serves: [coding]` (default). Voice and vision keep their own providers
   (`voice.conversation.*`, `config/schema/voice_conversation.ex`) and never enter this chain.

`provider_gate/2` changes from "every backend limited" to "no candidate allowed by the policy". When it holds,
the ticket stays queued without a slot and records the per-source reasons (section 5).

The two fallback paths call the same policy. `PausedFallback` asks for the next allowed candidate after the
limited backend instead of the single `configured_fallback`, so a claim paused on any priority position moves on.

That is #7879's fix expressed through the policy. This plan depends on #7879 landing first and only swaps its
"next available" lookup for a policy call (PCP-6). `RateLimitFallback` uses the same lookup for its target.

## 2. Config

The multi-project plan gives each field one owning layer
([config precedence](2026-11-06-multi-project-gateways.md#config-precedence-and-provenance)).

Capacity and money belong to the machine, and preference belongs to the project; the policy adds no layer.

| Key | Layer | Default | Meaning |
|---|---|---|---|
| `machine:capacity.sources.<backend>.billing` | L1 | `unknown` | `subscription`, `prepaid`, `metered` or `unknown` |
| `machine:capacity.sources.<backend>.last_resort` | L1 | `false` | Defer this source while any other allowed source exists |
| `machine:capacity.sources.<backend>.serves` | L1 | `[coding]` | Work kinds this source may take |
| `machine:capacity.sources.<backend>.reserve.percent` | L1 | `0` | Remaining percent workers must leave on the reserved accounts |
| `machine:capacity.sources.<backend>.reserve.accounts` | L1 | all accounts | Which `agent.accounts.<backend>` entries the reserve covers |
| `machine:capacity.sources.<backend>.limits.daily_usd` | L1 | `null` | Hard cap; also `weekly_usd`, `monthly_usd` (UTC calendar periods) |
| `machine:capacity.limits.<period>_usd` | L1 | `null` | Hard cap over all metered and prepaid sources together |
| `machine:capacity.default_burn_percent_per_hour` | L1 | `null` | Burn assumed for a running agent before one is learned (section 4) |
| `agent.priority`, `agent.routing` | L3 | as today | Order of routes; "Codex first" is `priority: [codex, claude, openrouter]` |
| `agent.usage_floor_percent` | L3 | `5` | Unchanged |
| `capacity.sources.<backend>.limits.*` | L3 | inherit | A project may lower a machine limit, never raise it |
| `capacity.sources.<backend>.reserve.percent` | L5 | inherit | `aiur set capacity.reserve.claude <n>` may raise the reserve at runtime, never lower it below L1 |

Rules:

- No `capacity` block anywhere means: every source `billing: unknown`, no reserve, no last resort, no limits. The
  policy then allows every route that today's gates allow, so behaviour is unchanged.
- A project can only tighten machine policy: lower limits, higher reserve, add `last_resort`. It cannot loosen.
- `aiur config explain capacity.<key>` (MPG-310) names the layer each effective value came from.
- `agent.usage_floor_percent` stays a project key because it is a dispatch preference, not money.

The operator's stated policy, as config:

```yaml
# ~/.aiur/machine
capacity:
  sources:
    claude:     { billing: subscription, reserve: { percent: 30, accounts: [default] } }
    codex:      { billing: subscription }
    openrouter: { billing: prepaid, last_resort: true, limits: { daily_usd: 5, monthly_usd: 40 } }
# <repo>/.aiur/config
agent:
  priority: [codex, claude, openrouter]
```

## 3. Per-provider telemetry: known vs unknown

All readings flow through the provider meter projection, polled every
`max(min(polling.usage_interval_seconds, agent.headroom_reading_max_age_seconds), 120)` seconds, 300 s by
default (`config/usage_cadence.ex:11-27`). A reading turns `:stale` after two probe intervals
(`provider_meter_projection.ex:36-37,362-373`); no reading is `:unknown` (`:410-411`).

Paths in this table are under `src/lib/aiur/`.

| Provider | Known (source, fields) | Unknown | Evidence |
|---|---|---|---|
| Claude (subscription OAuth) | `GET /api/oauth/usage` per account: `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet` used %, `resets_at`. Live `rate_limit/update` status `allowed`, `allowed_warning`, `rejected` with `resets_at` | Window size is implied by name, not reported. Event stream has no consumed fraction. API-key accounts have no usage at all. Executor vs worker share of one account is not separable | `claude/usage_api.ex:26,42-53`; `claude/rate_limit_adapter.ex:8-12`; `provider_meter_probe.ex:14-19,219-268`; `config/schema/agent.ex:180` |
| Codex (subscription) | `account/rateLimits/updated`: `primary` and `secondary` used % (integer), `windowDurationMins`, `resetsAt`, `planType`; `credits` as `hasCredits`/`unlimited` | Credit amount. Readings arrive only when a session starts or the probe runs, so an idle Codex keeps an old reading. Ledger is per backend, so several Codex accounts read as unknown | `codex/rate_limit_adapter.ex:258-300,395-406`; `provider_meter_probe.ex:8-12,42`; `concepts/headroom-dispatch.md` |
| OpenRouter (prepaid) | `GET /credits` with `OPENROUTER_MANAGEMENT_KEY`: `total_credits`, `total_usage`, giving remaining USD. Per-route spend from the usage aggregate | Per-key limit and its reset; rate limits. Without the management key the balance is unknown. A $0 balance is learned only by a 402 per claim (#7879) | `open_ai_compat/provider_meter_probe.ex:70,90-96,139-217`; `usage/provider/open_router.ex:202-311`; `open_ai_compat/transport.ex:50-61` |
| DeepSeek (prepaid) | `GET /user/balance`: USD `total_balance`. In-flight request count against a fixed 2500 | Used % is derived from a stored baseline, not reported. No rate limits or resets. No `aiur usage` adapter | `open_ai_compat/provider_meter_probe.ex:69,82-136`; `open_ai_compat/balance_baseline.ex:3-22`; `open_ai_compat/meter_windows.ex:4-21`; `usage.ex:6-14` |
| Moonshot / Kimi | Per-request token usage after the fact | Balance, limits, resets: everything before the request | `open_ai_compat/provider_meter_probe.ex:12-13`; `usage/headless/kimi/request_usage.ex` |
| Gemini, OpenAI (voice, vision) | Local `voice.conversation.daily_minutes_cap` (minutes) | Provider usage and balance; no meter | `config/schema/voice_conversation.ex:61-64`; `usage/price_table/data.ex:19-22` |
| ElevenLabs (voice) | `GET /v1/user/subscription` quota | Not a coding source; out of this policy | `eleven_labs/quota.ex:3-15` |

Not checked for this plan: whether OpenRouter's per-key endpoint and Moonshot's balance endpoint return limits
Aiur could poll. PCP-2 checks both before any code depends on them; until then they stay unknown.

Consequences for the policy:

- Spend for metered and prepaid sources comes from the usage aggregate's API-equivalent USD, the figure the
  spend cap already uses (`orchestrator/spend_cap/evaluation.ex:13-37`). Partial pricing coverage counts as
  unknown spend, which holds a source that has a limit.
- A prepaid balance reading, when present, also holds the source at `remaining <= 0`, before any 402.
- Moonshot, and OpenRouter without the management key, can only be governed by the USD limits Aiur records
  itself. The policy says so in its reason text instead of showing headroom.

## 4. Reservation model

Readings lag dispatch. Five tickets claimed inside one poll interval would all see the same Claude reading and
all pass the reserve. The ledger closes that gap without pretending to know more than the meters do.

**Hold before dispatch.** When the policy allows a candidate, `Aiur.Capacity.Ledger` records a hold
`{ticket, backend, account, kind, estimate, created_at}` in the same call. Kinds:

- `:window`, for subscription accounts: the estimate is `burn_percent_per_hour x expected_hours` against the
  binding window. Burn is learned per account as the change in used % between two readings divided by
  agent-hours run on that account in between (EWMA). Until learned it is `default_burn_percent_per_hour`; when
  that is `null` too, the estimate is unknown.
- `:usd`, for metered and prepaid sources: the estimate is the rolling median USD per turn for that backend and
  complexity from the usage aggregate. With no history it is the `max_output_tokens` cost bound OpenRouter
  already reserves (`config: agent.backend_configs.<backend>.max_output_tokens`).

**Projected remaining** for a candidate is the latest reading minus the open holds created after that reading
was observed. The reserve and limit rules compare projected remaining, not the raw reading.

**Unknown estimate.** On a reserved account, a hold with an unknown estimate makes projected remaining unknown,
so the account is held for further workers until the next reading. On an unreserved account it is recorded but
does not subtract, which is today's exploration behaviour.

**Reconcile after.** On every turn end the hold's `:usd` estimate is replaced by the recorded spend. On every
fresh reading for an account, holds older than that reading are folded into it: the reading already contains
their usage. A hold is closed when its agent stops. Each reconcile records `estimate` vs `actual` so burn and
per-turn estimates improve.

**Durability.** Holds are rebuilt on start from running agents and their dispatch records, so the ledger needs no
new file. Period spend is already durable in the usage aggregate.

**Running agents.** Nothing stops a running agent when a limit or reserve is crossed, as with the floor today.
The one exception is a hard USD limit: crossing it stops new turns on that source at the next turn boundary,
and the ticket re-enters the queue for the next allowed source.

## 5. Decision record

Today headroom writes `dispatch_selection = %{policy, pinned, backend, account, route, summary, candidates}`
(`headroom_dispatch.ex:246-258`) to the ticket's event stream (`agent_runner/dispatch_selection_event.ex:14-24`).

`aiur agents` prints only the account suffix (`control_cli/dispatch_account.ex:13-16`), and the dashboard shows
no reason. The record grows; it is not replaced:

```json
{
  "policy": "capacity/v1",
  "chosen": {"route": "codex", "account": "default", "reason": "preferred"},
  "candidates": [
    {"route": "codex", "account": "default", "verdict": "allow", "reading": {"remaining_percent": 62, "age_s": 40}},
    {"route": "claude", "account": "default", "verdict": "hold", "reason": "reserve",
     "detail": "projected 27% <= reserve 30% (reading 33%, 2 holds)"},
    {"route": "openrouter", "account": null, "verdict": "defer", "reason": "last_resort"}
  ]
}
```

Reason codes: `preferred`, `only_allowed`, `last_resort_used`, `pinned`, `reserve`, `limit_daily`,
`limit_weekly`, `limit_monthly`, `limit_global`, `balance_exhausted`, `spend_unknown`, `reading_unknown`,
`floor`, `limited`, `not_served`. Every code names its cause; there is no catch-all.

Where it shows:

- `aiur agents` and `aiur status`: the suffix adds the chosen reason, e.g. `codex/default (preferred)` or
  `openrouter (last_resort_used: claude reserve, codex limited until 18:00)`.
- A queued ticket with no allowed candidate shows `waiting: no authorized source` followed by one clause per
  source, in `aiur agents`, `aiur status` and the dashboard queue.
- The dashboard unit row (`aiur_web/operator_control_center/units_presentation.ex`) shows the same text.
- The `dispatch` telemetry point gains `reason` so section 8 can count it.

## 6. Consumable resource view ("Energy")

A client app needs one shared view of how much work Aiur can still start, without re-deriving the policy. It
reads the policy's own output; it never schedules.

`GET /api/v1/capacity` and `aiur capacity [--json]` return a new contract `aiur.capacity` v1, with a JSON
Schema in `packages/aiur-contracts/schemas/capacity.v1.schema.json` beside `aiur.usage`:

```json
{
  "contract": "aiur.capacity", "contract_version": 1, "observed_at": "...",
  "energy": {"state": "available", "level": 0.62, "binding_source": "codex", "unknown_sources": ["moonshot"]},
  "sources": [{
    "backend": "claude", "billing": "subscription", "serves": ["coding"], "last_resort": false,
    "state": "reserved",
    "accounts": [{"account": "default", "reserved": true, "remaining_percent": 33, "projected_percent": 27,
                  "reserve_percent": 30, "resets_at": "...", "observed_at": "...", "age_ms": 40000,
                  "freshness": "fresh", "open_holds": 2}],
    "limits": [], "reason": "reserve"
  }]
}
```

- `state` per source: `available`, `last_resort`, `reserved`, `limited`, `exhausted`, `held`, `unknown`.
- `energy.level` is the largest remaining fraction any allowed, non-last-resort source has above its reserve or
  limit, from 0 to 1. It is `null` when no source has a known figure; `state` is then `unknown`. A client must
  render `null` as unknown, never as full.
- Every figure carries `observed_at`, `age_ms` and `freshness`, as `aiur.usage` does.
- The view is computed by the same functions dispatch calls, so the two cannot disagree.

## 7. Implementation tickets

Filed with `needs-triage` and `agent:parked` so they wait for operator triage, each with its dependencies:

| Id | Issue | Title | Depends on |
|---|---|---|---|
| PCP-1 | #7886 | Capacity policy config schema at L1 and L3, no-op defaults, docs | - |
| PCP-2 | #7887 | Spike: OpenRouter per-key limit and Moonshot balance endpoints | - |
| PCP-3 | #7888 | Pure capacity policy decision module with reason codes | PCP-1 |
| PCP-4 | #7889 | Apply the policy at dispatch; fold the usage floor into it; widen the decision record | PCP-3 |
| PCP-5 | #7890 | Reservation ledger: hold before dispatch, reconcile on reading and turn end | PCP-4 |
| PCP-6 | #7891 | Paused and running fallback pick the next policy-allowed source | PCP-4, #7879 |
| PCP-7 | #7892 | Show the decision reason and "no authorized source" in agents, status, dashboard | PCP-4 |
| PCP-8 | #7893 | `aiur.capacity` contract, `GET /api/v1/capacity`, `aiur capacity` | PCP-5 |
| PCP-9 | #7894 | Capacity samples and the reserve/Codex-share report | PCP-4 |

PCP-1 and PCP-2 can start in parallel. The critical path is PCP-1, PCP-3, PCP-4, PCP-5, PCP-8.

## 8. Validation plan

Measure against the live daemon, not the mechanism. PCP-9 adds the two data sources this needs:

- a capacity sample every probe interval, appended to `<run-log-root>/log/capacity.ndjson`: per account, reading,
  projected remaining, reserve, open holds, freshness;
- `reason` on the `dispatch` telemetry point (PCP-4).

Metrics, each over seven days before and seven days after the policy is enabled in `~/.aiur/machine`:

| Claim | Metric | Pass |
|---|---|---|
| Claude reserve holds | Worker dispatches to a reserved account whose projected remaining was at or below its reserve | 0 |
| Claude reserve holds | Samples where a reserved account's binding window was at or below its reserve, split by whether a worker was running on it | Every such sample with a worker running is explained by a hold estimate that undershot, and is listed |
| Codex share rises | Codex dispatches / all coding dispatches | Higher than the before window, reported with both counts |
| OpenRouter is last resort | OpenRouter dispatches whose record has another candidate `allow` | 0 |
| Hard limits hold | Recorded USD per source and period vs its limit | Never above the limit by more than one turn's spend |
| Unknown is not shown as available | `aiur.capacity` sources with `freshness: unknown` and a non-null figure | 0 |

`aiur capacity report --since <date>` (PCP-9) prints these with population counts. A before window recorded
under a different `agent.priority` is not comparable; the report states the priority in force for each window.

## Risks

- **Burn estimate quality.** If learned burn undershoots, parallel claims can push a reserved account below its
  reserve. The metric in section 8 lists every such case so the default can be tuned.
- **Shared accounts.** The Executor and workers share the meter for one Claude login. The reserve protects the
  total, which is what the operator asked for, but cannot tell who spent it.
- **Fail-closed reserve.** A Claude meter outage holds reserved accounts for workers. That is intended; the
  reason text names the outage so it is not read as exhaustion.

## Scope out

Buying capacity, bypassing provider limits, choosing the Executor's provider, and voice or vision routing.

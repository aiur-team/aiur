---
title: "MP-R1-GHA-3: Cut the remaining github-access to aiur edges - Plan"
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: brainstorm.md
ticket_id: MP-R1-GHA-3
complexity: 3
blocked_by: [MP-R1-GHA-2, MP-R1-C7-T06 (#3301), U8-P22-T04 (#3492)]
base_sha: d2a022fad
date: 2026-10-09
---

# MP-R1-GHA-3: Cut the remaining github-access to aiur edges - Plan

## Summary

Replace the access layer's last references to aiur modules with ports that the
settings struct carries: a freshness port for webhook mode, request taggers for caller
attribution, a poll-owner and recovery target, a PubSub name, and a reachability probe
through `Transport`. After this ticket the `github-access.tsv` allowlist is empty.

## Problem frame

After GHA-2 the remaining access → outside edges (brainstorm.md §4.3) are:

| Site | Today | After |
|---|---|---|
| `read_cache/policy.ex` `ttl_ms/2`, transport lookup | `Aiur.Webhooks.ModeTable.transport/1`, `Webhooks.DeliveryMode` type | `settings.freshness.transport(repo)` returning `:webhook \| :polling`; github-listeners' `ModeTable` implements it |
| `transport.ex` request path | `QueueCost.tag/1` (build-queue attribution), `RequestOrigin.mark/1` (LiveView check) | `settings.request_taggers` list, applied in today's order; `QueueCost` moves to `github` |
| `transport.ex` `orchestrator_process?/0` | C7-T06 app env `:github_poll_owner` | `settings.poll_owner` |
| `quota.ex` recovery send | C7-T06 app env `:github_quota_recovery_target` | `settings.recovery_target` |
| `resource_events.ex` | `@pubsub Aiur.PubSub` | `settings.pubsub` |
| `connectivity.ex` | `Aiur.GitHub.Client` probe | `Transport` probe of the same endpoint and caller |
| alert defaults (5 files) | `Signal.alert/2` after C7-T06 | `settings.alert_sink`, default `&Signal.alert/2` |

`signal` stays an allowed dependency (kernel layer), so the alert sink default may name
it; the field exists so a standalone consumer can pass its own.

## Requirements

- R1, R2, R7, R8 (brainstorm.md).

## Key technical decisions

- **Freshness port is owned by github-access.** Behaviour
  `Aiur.GitHub.Access.Freshness` with `transport(repo_slug)`; default when unset is
  `:polling` (today's fail-safe, `ModeTable` moduledoc "Failing safe"). This supersedes
  C7-T06's "ModeTable reassigned to github": ModeTable stays in github-listeners and
  implements the port (a downward edge listeners → access).
- **Taggers are an ordered list of `(request -> request)` functions** supplied by the
  domain; github-access applies them before `CredentialSelector.assign/1`, exactly where
  `QueueCost.tag/1` runs today. `RequestOrigin` stays in access as the default view
  tagger only if it has no Phoenix reference; otherwise it moves to `github` too.
- **Verdict refusals unchanged.** `@unsafe_selections` and `@unsafe_rest` are not
  touched and get no setting (KD7). The caller-name rows (`"ci_required_checks"` ...)
  stay as string data in `policy.ex`.
- **No new process, no start-order change.** Ports are plain values in the settings.

## Implementation units

### U1. Freshness port

**Files:** `src/lib/aiur/github/access/freshness.ex` (new);
`src/lib/aiur/github/read_cache/policy.ex`; `src/lib/aiur/webhooks/mode_table.ex`
(`@behaviour`); `src/lib/aiur/github/access_settings.ex`;
`src/test/aiur/github/read_cache/freshness_port_test.exs` (new).
**Test scenarios:**
- A webhook-mode repo gets the long TTL bucket, a polling repo the short one, through a
  stub port. **Mutation:** ignore the port and return `:polling`; the webhook case fails.
- Port unset → `:polling` TTLs (guard; passes before and after).
- The `@unsafe_selections` refusal still answers `{:no_cache, _}` for a
  `statusCheckRollup` query under a webhook-mode port (R8 guard).

### U2. Request taggers and QueueCost move

**Files:** `src/lib/aiur/github/transport.ex`; `src/lib/aiur/github/queue_cost.ex`
(ownership to `github`); `src/lib/aiur/github/access_settings.ex`;
`src/test/aiur/github/quota_caller_attribution_test.exs`.
**Test scenarios:**
- A label POST made under `Process.put(:aiur_ticket_writer, :build_queue)` is attributed
  `build_queue_label_post` (existing behaviour). **Mutation:** empty tagger list; fails.
- A static-provider transport with no taggers keeps the caller set by `put_caller/2`.

### U3. Poll owner, recovery target, PubSub, connectivity, alert sink

**Files:** `transport.ex`, `quota.ex`, `resource_events.ex`, `connectivity.ex`, the five
alert-default files, `src/config/config.exs` (drop C7-T06 keys once the settings carry
them), `src/test/aiur/github/quota_test.exs`, `src/test/aiur/github/connectivity_test.exs`.
**Test scenarios:**
- Recovery notifies `settings.recovery_target`; nil target → no send. **Mutation:**
  hard-code `Aiur.Orchestrator`; fails.
- Request attribution for the poll owner is unchanged (`aiur github-cost` per-caller rows
  for an orchestrator-issued request).
- `ResourceEvents.subscribe/1` with a test PubSub name receives a deposit event.
- Connectivity probe issues one request through `Transport` with today's caller name.

### U4. Allowlist to zero and rule tightening

**Files:** `scripts/components/allowlist/github-access.tsv` (empty or removed).
**Verification:** checker `--prune` green; `git grep -nE
'Aiur\.(Orchestrator|Webhooks|BuildOrder|Alerts|PubSub)\b'` over access files returns
only doc comments.

## Risks

- **TTL regression** on webhook repos if the port is wired to the wrong repo slug.
  Mitigation: U1 mutation test; `read_cache` metrics unchanged on a manual `aiurdev --test`
  run (hit/refusal counters move as before).
- **Overlap with C7-T06 config keys.** This ticket removes them after it reads the same
  values from settings; one release carries both.

## Definition of done

- github-access allowlist empty; tests pass and fail under mutation; manual run shows
  AgentList GitHub rows and `aiur github-cost` rows as before.

---
title: "fix: Separate daemon GitHub auth and throttle polling before exhaustion"
date: 2026-07-11
type: fix
status: completed
issue: 678
---

# fix: Separate daemon GitHub auth and throttle polling before exhaustion

## Summary

Aiur currently resolves one `GITHUB_TOKEN` (with `gh` keyring fallback) and uses
it for every daemon GitHub API request. Under sustained polling, the daemon can
consume that credential's hourly allowance independently of the operator's CLI
session. Existing connectivity handling backs off only after individual sources
fail, so the comment-to-rework loop and other tracker work can degrade together
before the fleet reacts.

This plan gives the daemon an explicit credential that can belong to a dedicated
bot account while preserving current installations, then turns successful
GitHub responses into one shared rate-budget signal. The orchestrator uses that
signal to pace the complete GitHub API poll cycle before exhaustion, while
existing per-source `Retry-After` and connectivity handling remain the reactive
fallback.

## Problem Frame

- `Aiur.GitHub.Config` resolves only `GITHUB_TOKEN`, so operators cannot assign
  long-lived daemon polling a separate identity without also changing the token
  inherited by agents and `gh`.
- `Aiur.GitHub.Connectivity` and `Aiur.Orchestrator.TrackerHealth` keep
  source-local failure delays. They do not combine successful
  `X-RateLimit-Remaining` / `X-RateLimit-Reset` observations into a shared
  pre-exhaustion decision.
- One orchestrator cycle performs the firehose, watched-comment, CI, command
  scan, running-state, and candidate-ticket reads. A fixed interval and fixed
  target caps can therefore spend the remaining allowance faster than the reset
  window replenishes it.
- Producer consolidation from #680 and request reductions from #684 remain in
  place. `Aiur.Events.LsRemoteTicker` uses `git ls-remote`, not the GitHub REST
  API, and is not part of HTTP quota pacing.

## Requirements

- **R1** Operators can provide a dedicated daemon GitHub token without changing
  `GITHUB_TOKEN` as seen by agents or the operator's `gh` CLI.
- **R2** Existing installs that define only `GITHUB_TOKEN` continue to work with
  the current validation and keyring fallback behavior.
- **R3** Successful GitHub REST and GraphQL responses update one shared view of
  the primary quota limit, remaining quota, and reset time without exposing
  token material.
- **R4** When observed quota is low relative to the reset window, all
  orchestrator-owned GitHub API polling is delayed together before the allowance
  reaches zero.
- **R5** A user-requested refresh may be queued immediately but must not bypass
  an active protective budget delay.
- **R6** A `403`/`429` continues to honor `Retry-After` and existing per-source
  connectivity backoff; malformed or missing headers never crash or stall the
  workflow.
- **R7** ETag-driven firehose `304` responses, comment target caps, CI semantics,
  and `LsRemoteTicker` behavior remain unchanged.
- **R8** Operator-facing setup and auth diagnostics explain which credential the
  daemon selected and how to configure a dedicated bot credential without
  printing either secret.

## Scope Boundaries

### In Scope

- Daemon token selection, boot-time validation, setup templates, and auth
  diagnostics.
- Central capture and pure interpretation of GitHub primary-rate-limit headers.
- Orchestrator poll-cycle pacing based on the shared budget, composed with the
  current source-local delays.
- Focused regression tests plus the repository CI gate.

### Out of Scope

- Provisioning, rotating, or storing a GitHub bot account/token for the user.
- Reassigning event producer ownership delivered by #680/#684.
- Replacing GitHub's ETag support, fixed per-cycle target caps, or reactive
  secondary-rate-limit handling.
- Coordinating quota state across separate Aiur OS processes or hosts.
- Applying HTTP quota policy to `git ls-remote`, which exposes no REST response
  headers.

## Assumptions

- The dedicated environment variable will be `AIUR_GITHUB_TOKEN`; it is
  daemon-specific by name and does not affect `gh`'s standard `GITHUB_TOKEN` /
  `GH_TOKEN` precedence.
- `AIUR_GITHUB_TOKEN` takes precedence when present. An invalid configured value
  fails daemon preflight with source-specific recovery guidance instead of
  silently spending the operator credential. Only an absent dedicated value
  enters the existing `GITHUB_TOKEN` then keyring compatibility chain.
- The shared budget observes all in-process GitHub responses but gates the
  orchestrator's background poll cycle. User-triggered writes are not delayed by
  the proactive gate, though their response headers improve the shared estimate.
- Protective pacing begins at the larger of 100 requests or 10% of the observed
  primary limit. At or below that reserve, background polling waits until the
  observed reset plus a one-second margin. A defensive one-hour timer cap avoids
  trusting a corrupt far-future reset forever; the next decision re-evaluates
  the same observation. Constants are policy in one module, not new workflow
  YAML, until dogfood data shows operator tuning is necessary.

## Key Technical Decisions

- **KTD1 — Dedicated env token with fail-closed selection and compatibility
  fallback.** Extend the existing one-time resolver instead of adding a second
  client stack. When the daemon-specific variable is configured, select it and
  let preflight surface invalid credentials; do not silently substitute the
  operator identity. When it is absent, preserve the existing environment and
  keyring recovery chain. Cache only the selected daemon credential in the
  existing private persistent-term slot.
- **KTD2 — Observe at the transport boundary.** The shared REST/GraphQL request
  function is the only reliable place every production response passes through.
  Record rate headers there after a request completes; injected request
  functions used by unit tests remain isolated unless they explicitly exercise
  the budget module.
- **KTD3 — Store observations in a supervised rate-budget process.** A small
  process serializes concurrent response updates from comment/CI tasks and
  exposes a read-only delay calculation. It starts before the orchestrator so
  boot and poll code never races an absent registry. Missing process/header data
  degrades to no proactive delay.
- **KTD4 — Pace whole cycles, not individual endpoints.** Compose the calculated
  budget delay with `TrackerHealth.next_poll_delay_ms/1` by taking the maximum.
  This preserves GitHub's per-source `X-Poll-Interval` and reactive failure
  delays while preventing one producer from continuing to spend a shared token
  during another producer's backoff.
- **KTD5 — Reserve the final 10% and treat reset as wall-clock data.** Use the
  larger of 100 requests or 10% of the observed limit as a protected reserve;
  once remaining quota enters it, return the time until reset plus one second,
  capped at one hour. Parse GitHub's reset epoch defensively, calculate the
  remaining window from an injectable clock, and return only a relative
  millisecond delay to lifecycle scheduling. Stale resets clear the protection
  rather than wedging polling.

## High-Level Technical Design

```text
GitHub REST / GraphQL response
             |
             v
 Transport records limit + remaining + reset
             |
             v
   shared GitHub RateBudget process
             |
             v
  TrackerHealth next-cycle decision
       /                    \
per-source reactive      proactive shared
backoff / poll interval  budget pacing
       \                    /
        max(delay values)
             |
             v
       next poll cycle
```

The rate-budget process is advisory, not an authorization boundary. Request
classification and existing error values remain owned by `Errors` and
`Connectivity`; the new policy only supplies an additional scheduling delay.

## Implementation Units

### U1. Add a daemon-specific credential chain

**Goal:** Select a dedicated daemon credential without changing agent/operator
CLI auth or breaking existing environments.
**Requirements:** R1, R2, R8
**Dependencies:** none
**Files:**
- `src/lib/aiur/github/config.ex` (modify)
- `src/lib/aiur/github/auth_preflight.ex` (modify)
- `src/test/aiur/github/config_test.exs` (modify)
- `src/test/aiur/github/auth_preflight_test.exs` (modify)

**Approach:**
- Extend the one-time resolver to consider `AIUR_GITHUB_TOKEN` first, retaining
  validation, keyring lookup with standard GitHub token variables cleared, and
  last-resort compatibility behavior.
- Track a non-secret source label alongside the selected credential so preflight
  diagnostics name the actual source rather than hard-coding `GITHUB_TOKEN`.
- Keep `token/0` as the internal client accessor; callers do not branch on env
  names.

**Test scenarios:**
- Valid daemon token plus valid `GITHUB_TOKEN` selects the daemon token and
  reports its source.
- Invalid configured daemon token remains selected and fails preflight without
  trying `GITHUB_TOKEN` or keyring; when the daemon variable is absent, invalid
  standard env still falls through to a valid keyring credential.
- Only `GITHUB_TOKEN`, only keyring, and unresolved raw-env compatibility cases
  retain their current results.
- Diagnostics name the selected/failed source, never contain any token value,
  and give recovery instructions for both the dedicated and compatibility paths.

### U2. Capture and interpret shared GitHub rate budget

**Goal:** Convert concurrent successful-response headers into one safe,
testable proactive delay.
**Requirements:** R3, R6
**Dependencies:** none; can be implemented before transport wiring
**Files:**
- `src/lib/aiur/github/rate_budget.ex` (add)
- `src/test/aiur/github/rate_budget_test.exs` (add)
- `src/lib/aiur.ex` (modify supervision order)

**Approach:**
- Add a supervised process holding the newest valid remaining/reset observation.
- Keep parsing and delay policy as pure functions; process callbacks only fold
  observations and answer the current delay.
- Ignore missing, malformed, or older reset windows. Within the same reset
  window, retain the lowest observed remaining count so out-of-order concurrent
  responses cannot make the budget look healthier; a newer reset window begins
  a fresh observation. Clear expired windows and bound the returned delay with
  named policy constants.
- Log state transitions into and out of protective pacing at useful levels,
  without per-request spam.

**Test scenarios:**
- A healthy high-remaining observation yields no proactive delay.
- Remaining quota above the larger of 100 or 10% of limit yields no proactive
  delay; quota at or below that reserve waits until reset plus the safety margin.
- A far-future reset is capped at one hour and re-evaluated on the next cycle;
  lower remaining within the same window produces no shorter delay.
- Reset already passed, malformed numeric headers, and missing headers yield no
  delay and do not erase a newer valid observation incorrectly.
- Concurrent observations converge on the newest reset window and the minimum
  remaining count within that window; an older late response cannot increase
  the estimate.
- Process absence returns zero delay, allowing isolated components and shutdown
  paths to continue safely.

### U3. Wire response observation through shared transport

**Goal:** Feed the budget from every production GitHub REST and GraphQL
response without duplicating parsing across clients.
**Requirements:** R3, R6, R7
**Dependencies:** U2
**Files:**
- `src/lib/aiur/github/transport.ex` (modify)
- `src/test/aiur/github/transport_test.exs` (modify)

**Approach:**
- Wrap each production `Req` result once, forwarding response headers to the
  rate-budget process before returning the original value unchanged.
- Do not change status classification, body parsing, ETag handling, or injected
  request-function contracts.

**Test scenarios:**
- REST GET and a mutating request record valid remaining/reset headers and return
  the original response unchanged.
- GraphQL uses the same observation path.
- Transport errors and responses without rate headers preserve their exact
  return shape and do not manufacture a budget observation.
- Existing ETag and authentication-header tests remain green.

### U4. Compose proactive budget pacing with orchestrator scheduling

**Goal:** Delay every orchestrator-owned GitHub API poll source together before
quota exhaustion while preserving immediate work once the budget is healthy.
**Requirements:** R4, R5, R6, R7
**Dependencies:** U2, U3
**Files:**
- `src/lib/aiur/orchestrator/tracker_health.ex` (modify)
- `src/lib/aiur/orchestrator/lifecycle.ex` (modify if refresh clamping belongs at
  the scheduling boundary)
- `src/test/aiur/orchestrator/tracker_health_test.exs` (modify)
- `src/test/aiur/orchestrator/lifecycle_test.exs` (modify)

**Approach:**
- Include the shared rate-budget delay in the existing next-poll maximum rather
  than introducing a second timer.
- Clamp operator refresh scheduling to the active protective delay. Preserve
  coalescing and the response contract so the request remains observably queued.
- Leave the current source-local success/failure state and `Retry-After`
  normalization intact.

**Test scenarios:**
- Healthy budget returns the current fixed/source-derived interval unchanged.
- Protective delay larger than the firehose poll interval or reactive backoff
  becomes the next-cycle delay; a larger reactive delay still wins.
- An operator refresh during protection schedules at the protection boundary,
  while a healthy refresh remains immediate and repeated refreshes coalesce.
- Clearing/expiring the budget restores the ordinary polling interval.
- `LsRemoteTicker` tests remain unchanged and never consult the HTTP budget.

### U5. Document and scaffold dedicated-token setup

**Goal:** Make credential separation discoverable and safe for new and existing
operators.
**Requirements:** R1, R2, R8
**Dependencies:** U1
**Files:**
- `src/lib/aiur/init/templates.ex` (modify)
- `src/README.md` (modify)
- `AGENTS.md` (modify operational Auth note if still accurate for dogfood)
- `src/test/aiur/init/templates_test.exs` (modify)
- `src/test/aiur/init_test.exs` (modify where setup output changes)

**Approach:**
- Add a commented/empty `AIUR_GITHUB_TOKEN` entry and explain that it should
  belong to a dedicated bot for daemon polling; keep `GITHUB_TOKEN` documented
  as the compatibility and agent/operator credential.
- Update setup/auth copy to describe precedence and least-privilege expectations
  without suggesting that Aiur provisions or rotates the token.

**Test scenarios:**
- New GitHub setup templates contain both variable names and concise separation
  guidance, without populating either secret.
- Existing `.env` files are not overwritten during re-init.
- Setup output remains actionable when only the compatibility token is present.

## Verification

- Focused credential, rate-budget, transport, tracker-health, lifecycle, and init
  tests listed in U1-U5.
- `mix compile --warnings-as-errors`
- `mix format --check-formatted`
- `mix test`
- `mix lint`
- `mix dialyzer`
- `make ci` from `src/` as the repository gate.
- Manual CLI/TUI verification is required only if implementation exposes new
  operator-visible status or alert content. If it does, run the guarded real
  `scripts/aiurdev --test` recipe from an operator repo; this issue workspace
  must report the guard rather than bypass it.

## Risks and Mitigations

- **A stale/incorrect observation delays work too long.** Require a future reset,
  reject older windows, cap delay, and clear expired state.
- **Concurrent comment/CI responses reorder observations.** Serialize updates
  and define ordering explicitly by reset window and remaining count.
- **An urgent operator action is starved.** Gate background cycle scheduling,
  not user-triggered GitHub writes; refresh remains queued and visible.
- **Credential fallback hides a misconfigured bot token.** A configured
  dedicated token never falls back; preflight names its non-secret source and
  blocks polling until the operator fixes or deliberately removes it.
- **Policy is too conservative or too weak under dogfood load.** Keep reserve and
  pacing constants centralized and log transitions so post-merge observations
  can tune one module without changing producer behavior.

## Sequencing

1. U1 establishes explicit daemon identity and diagnostics.
2. U2 adds the isolated, pure-tested budget policy and supervised state.
3. U3 feeds it at the transport boundary.
4. U4 makes the policy effective for the whole poll cycle.
5. U5 updates onboarding and operational documentation.
6. Run focused tests after each unit, then the full repository gate and review
   the final diff for token leakage and timer edge cases.

## References

- Issue #678 and the 2026-07-11 post-V2 reassessment.
- #680 (producer consolidation) and #684 (PR fetch reduction).
- GitHub REST API guidance: rate-limit responses expose remaining quota and reset
  time, while rate-limit errors may carry `Retry-After`:
  `https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api`.
- Existing patterns: `src/lib/aiur/github/config.ex`,
  `src/lib/aiur/github/transport.ex`, `src/lib/aiur/github/connectivity.ex`, and
  `src/lib/aiur/orchestrator/tracker_health.ex`.

---
title: Hosted execution fails closed
execution: code
artifact_readiness: implementation-ready
issue: 5699
---

# Hosted execution fails closed

## Goal

Add an explicit, read-once hosted execution mode that refuses to boot or dispatch
unless every dispatchable harness proves three properties: permissions cannot be
bypassed, agent-directed commands have no network access, and provider or system
credentials are not reachable from the agent boundary. Preserve today's local
execution behavior and defaults.

## Requirements

- `instance.mode` accepts `local` (default) and `hosted`; existing configurations
  remain local.
- The mode is immutable for a running daemon. A workflow reload that changes it
  is rejected with a restart-required error rather than silently changing or
  weakening the booted trust boundary.
- Hosted validation runs before the supervision tree starts and also participates
  in the semantic validation used before dispatch and on config reload.
- The guard evaluates every backend eligible for dispatch, including fallback and
  per-ticket routes, rather than only `agent.kind`.
- Claude's `bypassPermissions` mode is always unsafe in hosted mode.
- A Codex turn policy is network-safe only when its effective
  `networkAccess` value is explicitly `false`; omission, `true`, an unknown policy,
  and danger-full-access fail closed.
- A harness is credential-safe only when its registry capability explicitly says
  provider credentials stay on the trusted daemon side. Every registered agent
  environment contributor must independently declare that it exposes no system
  credential; missing and unknown declarations are unsafe.
- Validation returns all discovered violations in deterministic order so an
  operator can see the complete unsafe profile in one attempt.
- Local mode does not invoke hosted restrictions and retains current Claude and
  Codex defaults.

## Context and research

- `Aiur.Harness.Capabilities` already projects registry-owned harness facts. The
  MP-R7 physical package move referenced by the issue is currently a documented
  NO-GO, but this logical capability seam exists on `main`, so this ticket does not
  depend on the cancelled physical move.
- `Aiur.Config.SemanticChecks` is called from the tracker-health dispatch gate and
  workflow reload. `Aiur.Application.start/2` has a pre-supervisor `with` chain for
  boot-fatal compatibility checks.
- Codex defaults to a workspace-write turn policy with network access. Claude
  defaults to `bypassPermissions`. Current Codex, Claude and Muse processes also
  receive provider profile locations, and the GitHub environment contributor
  exposes a readable token-file path to governed agent commands.
- OpenAI's sandbox guidance says agent-generated code can reach files,
  credentials, and network made available to its environment, and recommends
  keeping long-lived credentials outside that environment behind a trusted proxy:
  <https://developers.openai.com/api/docs/guides/agents-api/environments/security>.
- Anthropic's CLI reference documents both permission modes and the dangerous
  permission-bypass flag, supporting an explicit rejection rather than treating
  the current default as safe:
  <https://docs.anthropic.com/en/docs/claude-code/cli-usage>.

## Key technical decisions

1. **Mode belongs to the instance, not an individual provider.** Hosted execution
   is a deployment trust boundary. A global, read-once `instance.mode` prevents a
   route or fallback from escaping a provider-local safety toggle.
2. **Harnesses and environment contributors declare facts; the policy module
   decides.** Extend the existing harness capability projection with permission,
   network, and provider-credential-boundary facts, and give environment
   contributors a separate system-credential exposure declaration. The hosted
   validator interprets those facts alongside parsed config. This avoids
   provider-name branching and gives later proxy, Git publication, and
   remote-worker tickets explicit capabilities to upgrade.
3. **Unknown is unsafe.** Missing registry keys, unrecognized values, config read
   failures, and policies without an explicit network denial all produce hosted
   violations. A new backend cannot become hosted-safe accidentally.
4. **Boot and dispatch share one pure evaluator.** The application preflight and
   semantic check use the same evaluator and error shape. This prevents startup
   and hot-reload/dispatch policy from drifting.
5. **Do not weaken local defaults in this ticket.** Local Mix tooling relies on
   loopback network access and today's Claude automation relies on noninteractive
   permission handling. Hosted mode is opt-in and strict; broader default changes
   are a separate product decision.
6. **Current credential-bearing backends remain refused.** This ticket establishes
   the guard, not the broker. Follow-up tickets for API-key profiles, daemon-owned
   Git publication, model-call proxies, and remote sandbox VMs can change explicit
   capability declarations once their boundaries are real.

## High-level technical design

```text
 parsed settings + registry entries + environment contributors
             |
             v
 hosted safety evaluator ---- local mode ----> ok
             |
             +-- dispatchable harnesses
             |      permission claim + effective setting
             |      network claim + effective setting
             |      credential-boundary claim
             |
             +-- environment contributors
             |      system-credential exposure claim
             |
             +-- deterministic violation list
                         |
             +-----------+------------+
             |                        |
        application boot         semantic validation
        refuses supervisor       holds dispatch/reload
```

## Implementation units

### U1: Explicit instance mode

Files: `src/lib/aiur/config/schema/instance.ex`, `src/lib/aiur/config.ex`,
workflow fixture support, config schema tests, annotated examples, and
`website/docs-app/reference/configuration.md`.

Add the `local | hosted` schema value, accessor, boot snapshot, template examples,
and configuration reference. Test the default, accepted values, invalid values,
and that the boot snapshot remains authoritative after a config reload.

### U2: Conservative harness safety capabilities

Files: `src/lib/aiur/harness/capabilities.ex`, provider registry entries under
`src/lib/aiur/coding_agent/providers/`, the OpenAI-compatible registry helper,
`src/lib/aiur/agent_environment/contributor.ex`, the GitHub environment
contributor, and capability/registry/contributor contract tests.

Project hosted permission, command-network, and provider-credential-boundary facts
from registry entries. Project system-credential exposure from every configured
agent environment contributor. Give undeclared entries and contributors explicit
`unknown` results. Declare current providers and the GitHub contributor according
to their actual boundaries, not their intended future state. Test renamed entries,
missing declarations, unknown values, and the complete production registries.

### U3: Shared hosted safety evaluator

Files: a small module under `src/lib/aiur/config/`, its focused test file, and
`src/config/config.exs` semantic-check registration.

Evaluate all dispatchable backends, combine registry facts with the effective
Claude and Codex settings, and return every violation in stable order. A local
configuration returns immediately. Hosted tests cover safe injected capabilities,
all three unsafe dimensions, disabled backends, priority-enabled backends, danger
full access, explicit network denial, unknown harness/contributor declarations,
agent-reachable system credentials, and aggregated output.

### U4: Startup and dispatch enforcement

Files: `src/lib/aiur/application/startup_checks.ex`, `src/lib/aiur.ex`, application
tests, and semantic-check tests.

Invoke the shared evaluator in the existing pre-supervisor startup chain and as an
always semantic check. Record the booted mode only after the preflight passes; keep
hosted restrictions sticky for a running hosted daemon. Test that an unsafe hosted
configuration returns before the supervisor starts, and that semantic validation
rejects the same profile while local validation remains unchanged.

### U5: Operator documentation and acceptance evidence

Files: existing configuration/concept documentation and PR local-test evidence.

Document hosted mode as a fail-closed boundary, list the enforced conditions, and
state plainly that current credential-bearing local harnesses are refused until a
brokered/remote harness declares the required capabilities. Add exact post-deploy
CLI steps to the PR body because the agent workspace cannot run the real TUI smoke.

## System-wide impact

- **Configuration lifecycle:** `instance.mode` is read once at boot. Reload rejects
  either direction of mode change; changing the deployment trust boundary needs a
  restart.
- **Dispatch:** tracker health receives the existing config-error path and holds all
  new work. No agent process is created from an unsafe hosted profile.
- **Provider registry:** new backends must state their hosted boundary. Missing facts
  remain valid for local mode but cannot satisfy hosted validation.
- **Agent environment:** contributors participate in the fail-closed census, so a
  harness cannot pass while a system integration still exposes a credential file.
  No environment plumbing is declared safe by assertion. Capability upgrades
  require the later implementation to remove actual credential/network reachability
  first.
- **Compatibility:** local mode keeps current defaults, provider selection, and
  environment behavior. There is no migration for existing installations.

## Verification contract

- Run schema, harness capability, hosted evaluator, application startup, semantic
  check, workflow example, and documentation guard tests selected by the affected
  test tool, capped at four cases.
- Run compile with warnings as errors, format, lint, bare-receive, and structural
  gates required by the repository.
- For every new behavior test, revert the production hunk in an isolated worktree,
  prove the test fails, restore it, and prove it passes.
- Self-review for fail-open gaps: a missing backend capability, a newly enabled
  backend, omitted network setting, or hot reload must never produce `:ok` in
  hosted mode.

## Risks and dependencies

- **False safety claim:** a registry declaration could get ahead of reality.
  Mitigation: initial harness and contributor declarations describe current unsafe
  boundaries, tests cover conservative defaults, and follow-ups must change code
  and capability together.
- **Partial routing coverage:** checking only the primary route would miss fallback
  or ticket-label selection. Mitigation: derive the population from the same
  dispatchable-backend view used by routing.
- **Boot/dispatch drift:** separate checks could disagree. Mitigation: both entry
  points call one pure evaluator and assert identical violations.
- **Stale prerequisite note:** #3478 and #3480 were conditional on a physical
  packaging GO decision that is now NO-GO. The existing logical registry seam is
  sufficient; do not copy or move harness packages in this ticket.

## Assumptions

### Stated

- Hosted mode must fail closed on permission bypass, agent network access, and
  agent-reachable credentials.
- Current unsafe defaults must not silently carry into hosted execution.

### Inferred

- Hosted mode is a deployment-wide instance property and read once at startup.
- A guard-only first increment may intentionally reject every currently
  credential-bearing harness until later hosted-execution tickets land.
- Deterministic aggregated failures are preferable to one-error-at-a-time startup.

### Out of scope

- Creating hosted API-key profiles or a model-call proxy.
- Moving branch push, pull-request creation, or comments into the daemon.
- Provisioning remote sandbox VMs or changing local-mode defaults.
- The cancelled physical MP-R7 harness package move.

## Manual acceptance

The agent workspace cannot run the real `aiurdev --test` TUI flow. Record a
post-deploy check in the PR body that starts the real CLI with `instance.mode:
hosted`, confirms an unsafe profile exits before the dashboard/agents start, then
switches back to `local` and confirms the same configuration boots normally.

---
title: "MP-R1-GHA-6: Record the github-access promotion test and promote on go - Plan"
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: brainstorm.md
ticket_id: MP-R1-GHA-6
complexity: 3
blocked_by: [MP-R1-GHA-4, MP-R1-GHA-5, MP-R7-C4-T03 (#3478)]
base_sha: d2a022fad
date: 2026-10-09
---

# MP-R1-GHA-6: Record the github-access promotion test and promote on go - Plan

## Summary

Answer the five criteria of `migration-plan.md` §5 for github-access with evidence. On
**go**, move it into an in-repo Mix project `packages/elixir/aiur_github_access/`, a path
dependency of `src/mix.exs`, using the form MP-R7-C4-T03 proves. On **no-go**, commit the
record, name the failing criteria, and file one follow-up ticket with a re-check date.

## Problem frame

R6: a physical package only when the promotion test passes. The form is fixed by
`migration-plan.md` §5 "Physical form": `packages/elixir/<app>/`, path dependency,
`src/` is not an umbrella, one `mix release` boot. MP-R7-C4-T02 (#3477) is the record
pattern; MP-R7-C4-T03 (#3478) proves the form first.

## Requirements

- R6, R7 (brainstorm.md).

## Key technical decisions

- **Record first, move second, in one ticket.** The record decides; the move is mechanical
  once GHA-2..GHA-4 hold. A no-go ends the ticket with the record (no partial move).
- **Criteria as evidence (directional):**
  1. Zero allowlisted violations in or out for 2 consecutive merged releases: from
     `scripts/components/allowlist/*.tsv` at the two release tags.
  2. Child specs declared by the component: github-access exposes a
     `child_specs(settings)` list (ReadCache, Quota, BrokerTimeout, BudgetBroker,
     CredentialHeadroom, AppTokenRefresher, ResourceStore, AgentCacheBridge) that the
     composition root inserts at today's positions in `src/lib/aiur.ex` (~358-404).
  3. State and tests move intact: `test/aiur/github/<access tests>` run with
     `mix test` inside the package with a static provider, without booting `Aiur.Application`.
  4. Config owned in the manifest: `owns.env`/`owns.state` from GHA-1; no `.aiur/config`
     section moves (sections stay literal `embeds_one`, MP-R1-C4-T05).
  5. Second consumer: the standalone `gh-access` wrapper (GHA-5) is a consumer of the
     broker and answer-store contract, not of the Elixir library. Criterion 5 for the
     library needs a named Elixir consumer or Kevin's statement that independent release
     is a need (brainstorm.md Q1). Record which applies.
- **Namespace at promotion.** Modules may move to `AiurGitHubAccess.*` here (KD1),
  touching only the facade's callers through `Aiur.GitHub.Access` aliases; or keep
  `Aiur.GitHub.*` names inside the package. Decide in the record by caller count.
- **Wrapper packaging is separate.** `packages/gh-access/` (GHA-5) is not moved into the
  Mix project; the Mix project embeds the wrapper and broker builds as priv files.

## Implementation units

### U1. Promotion record

**Files:** `docs/research/aiur-mobile-and-platform/bucket-1-refactor/MP-R1/github-access/promotion-record.md` (new).
**Test expectation:** none -- research record; each criterion cites a command output or file.

### U2. (go only) Package skeleton and move

**Files:** `packages/elixir/aiur_github_access/{mix.exs,lib/**,test/**,priv/**}`;
`src/mix.exs`; `src/lib/aiur.ex` (insert `child_specs/1`); `components.json` (paths,
`prior`, target); CI workflow job that tests the package alone.
**Test scenarios:**
- Package `mix test` passes without `src/` on the code path (static provider, temp root).
- Release boot check (MP-R7-C4-T05 pattern): the built release starts, and
  `Aiur.Application` child order equals the literal fixture from C7-T06 test 4.
- `src/` compiles and its GitHub suites pass with the package as a path dependency.
- `aiurdev --test` manual: AgentList GitHub rows load; `aiur github-cost` prints rows.

### U3. (no-go only) Follow-up

**Files:** none in repo; one new issue titled for the failing criteria, blocked by
whatever closes them.

## Risks

- **Boot order drift** when child specs move. Mitigation: the literal child-order
  fixture.
- **Test isolation:** many GitHub tests are `async: false` on process-global singletons
  (#2557). The package tests must start their own named processes; a test that needs
  the global app stays in `src/`.

## Definition of done

- Record merged; on go, package builds, tests alone and in `src/`, release boots, and
  `components.json` points at the package path.

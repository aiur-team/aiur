---
title: Run any GitHub repository with global Aiur defaults
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
status: implementing
---

## Problem and research

Starting a new repository with global settings should not require repository-local init. Workflow already discovers ~/.aiur/config; GitHub.Config already infers an omitted repo from origin; the shared launcher already loads repository dotenv before ~/.aiur/.env, with exported values winning and GitHub credentials kept as one group. Missing startup label setup and ambiguous Executor guidance made this incomplete in Khala. Reuse these paths rather than adding configuration layers or copying credentials.

## Product contract

R1: With no local config and an existing global config, launch announces the global source and target repository. No local config or credentials are generated. Local configurations retain precedence.
R2: Before any agent dispatch, global GitHub startup idempotently ensures lifecycle and marker labels, plus complexity labels used by config routing. No model/effort/alias labels are seeded. Existing overrides remain compatible; broader removal of label routing is out of scope.
R3: Reuse shell-export, global dotenv, repository dotenv and existing App/PAT/keyring credential resolution. Credentials remain outside Git. Missing token/repository or label write permission fails startup with actionable guidance; never dispatch with incomplete setup.
R4: Preserve explicit global repository settings; reject a different current origin rather than accidentally modifying another repository. Omit tracker.github.repo for portable defaults. Non-GitHub global configs do not create GitHub labels.
R5: Update aiur-run and existing user docs to describe fallback and automatic setup; init remains optional for repository-specific customization.

## Decisions and alternatives

Implement the pre-dispatch bootstrap in application startup after credential resolution and before supervision. This covers foreground/background and both launchers. Reuse Workflow, GitHub.Config and Labels.ensure; avoid a second init wizard. Creating local config copies would defeat shared defaults and create stale credentials. Do not change existing init label choices or remove existing model overrides. The user explicitly requires parent-owned implementation without Aiur agents and prioritizes speed.

## Implementation units

U1: Add GlobalConfigStartup preparation and integrate before supervisor startup; scope network writes to the resolved current repo.
U2: Tests for global launch target, required label requests/no model labels, idempotence, missing credentials and API errors, local/non-GitHub skip and repo mismatch. Prove behavior with the production hunk reverted in a clean isolated witness.
U3: Update existing CLI/config/quick-start/GitHub/skills docs and aiur-run instructions. Create the tracking issue without dispatch labels.
U4: Review, focused tests/compile/format/config-doc checks and PR; build a separate latest test release for the Khala agent without changing live releases. Report actual CLI/TUI verification separately.

## Risks and validation

Global startup now needs Issues write permission to create missing labels. Requests are bounded and idempotent; no deletion or modification of existing labels. A Read-only bot cannot complete bootstrap until permissions or labels are supplied. Startup must never resume an existing paused instance. No saving claim. Tests use injected transport and temporary homes, never live tracker state.

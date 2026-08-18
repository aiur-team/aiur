---
title: "fix: Close the crash-dump triage loop"
created_at: 2026-08-16
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Close the Crash-Dump Triage Loop

## Goal Capsule

- **Objective:** Classify the retained BEAM crash evidence, retire the release-environment bootfile family, stop daemon dump settings and stale dumps from propagating into agent workspaces, and surface every new daemon crash dump as an Executor attention carrying its slogan.
- **Authority:** Issue #1484 and the seven-dump evidence are authoritative; #1499 owns the reproduced stderr/group-leader lifecycle fix, while #1429/#1430 own the saturation interpretation and admission response.
- **Stop conditions:** Do not guard `io:put_chars`, erase existing forensic dumps across user workspaces, weaken the release-variable ownership contract from #1521, or claim the sparse `erl_child_setup: 104` dump proves a process-level cause.
- **Tail ownership:** Implementation includes a durable triage record, focused regression tests, scoped validation, PR self-review, and CI handoff against `main`.

---

## Product Contract

### Summary

Aiur distinguishes daemon crashes from child/tooling BEAM failures, prevents daemon-only crash settings and stale ignored dumps from entering new workspaces, and writes a durable needs-attention alert with a bounded crash slogan after an unexpected daemon exit.

### Problem Frame

The original seven dumps were never folded into the operational crash loop. Four bootfile failures came from release ERTS state crossing a child boundary, two stderr failures came from child Mix BEAMs whose owning pipe disappeared, and one native `erl_child_setup: 104` dump lacked an Erlang process or stack. The corpus had grown to 272 paths but only 23 unique hashes at the 2026-08-17 UTC rescan: most growth is copied artifacts, including a root dump accidentally committed by `15cdc513` and ignored dumps copied from the warm base into every workspace.

### Requirements

- R1. Record the original seven dumps with timestamp, slogan family, process count, current/crashing process and stack, and a cause or explicit insufficient-evidence finding.
- R2. Complete #1404/#1521's release boundary by scrubbing `ERL_LIBS`, while retaining the deliberate ownership checks for unrelated `ROOTDIR`, `BINDIR`, `EMU`, and `PROGNAME` values.
- R3. Keep daemon-owned `ERL_CRASH_DUMP` and `ERL_CRASH_DUMP_SECONDS` out of every shell, Port, and remote child environment so child failures cannot overwrite or impersonate daemon captures.
- R4. On unexpected daemon exit, if the daemon wrote a crash dump, persist one valid needs-attention alert containing a bounded slogan and dump path without blocking crash recording or agent reaping.
- R5. Remove the accidentally tracked dump, ignore conventional dumps at repository root, and prevent ignored warm-base dump artifacts from entering newly materialized workspaces while preserving tracked and warm build artifacts.
- R6. Preserve the stderr lifecycle fix in #1499 and the sparse native-helper interpretation in #1429/#1430 as separate, linked family outcomes.

### Acceptance Examples

- AE1. A child launched with release `ERL_LIBS` and daemon dump variables observes none of them, while unrelated release-launcher values covered by #1521's ownership tests remain preserved.
- AE2. A synthetic daemon dump with quotes, backslashes, or an oversized slogan produces valid bounded alert JSON with `needs_attention: true`; a missing dump produces no false dump alert.
- AE3. A warm base containing ignored root and nested `erl_crash.dump` files still materializes its tracked source and warm build cache, but the new workspace contains no copied dumps.
- AE4. The durable triage record labels each original family as fixed, linked, or insufficient evidence without upgrading inference to certainty.

---

## Planning Contract

### Key Technical Decisions

- KTD1 — Preserve #1521's ownership model. Keep conditional scrubbing for the four generic launcher variables because unrelated remote/user OTP values are a tested contract. Treat `ERL_LIBS` like `ERL_AFLAGS`: it is a process-global BEAM load-path override and must not cross from the daemon into agent toolchains.
- KTD2 — Separate daemon capture from child execution. Unset both crash-dump variables in the central shell scrub and the Port-compatible workspace environment so every current child path receives the same contract.
- KTD3 — Alert outside the dead BEAM. Extend the bash BEAM-death watchdog's durable record path; the supervised `Aiur.Alerts` process cannot emit after its VM exits. JSON encoding is bounded and best-effort so parsing or disk failure never delays reaping.
- KTD4 — Stop propagation without deleting user evidence. Remove the tracked artifact and clean only ignored conventional dump files from a newly copied warm-base stage. Existing workspace dumps remain available for forensic/manual cleanup.
- KTD5 — Keep family ownership explicit. #1499's reproduced process-group teardown owns stderr repair, and the pre-cap `erl_child_setup` dump remains insufficient evidence whose current-build confirmation path is already documented under #1429/#1430.

### Scope Boundaries

- No new config key, CLI flag, or user-facing surface is introduced; website documentation is not required.
- This change does not recursively delete dumps from existing workspaces or unrelated repositories under the operator's home directory.
- This change does not reopen #1499's closed draft implementation or run the operator-only saturation reproduction.

### Sources & Research

- `src/lib/aiur/agent_environment.ex` is the shared child-environment boundary.
- `packaging/npm/aiur-cli/libexec/aiur-engine.sh` owns daemon dump capture and the post-BEAM watchdog.
- `src/lib/aiur/workspace/materialize.ex` copies ignored warm artifacts into ticket workspaces.
- `docs/measurements/2026-08-03-daemon-saturation-root-cause.md` records the bounded `erl_child_setup: 104` interpretation.
- #1521 deliberately hardened conditional launcher ownership; #1499 reproduced stderr loss as reparented child process-group teardown.
- No `CONCEPTS.md` or `docs/solutions/` institutional-learning corpus exists. External research was skipped because the decisions are repository-specific and fully evidenced by current code, dumps, and linked work.

---

## Implementation Units

### U1. Seal daemon and release environment boundaries

- **Goal:** Prevent release libraries and daemon dump destinations from reaching child BEAMs.
- **Requirements:** R2, R3
- **Files:** `src/lib/aiur/agent_environment.ex`, `src/test/aiur/agent_environment_test.exs`
- **Approach:** Add `ERL_LIBS` to the unconditional Erlang scrub and add both dump variables to shell and Port unsets, relying on existing central call sites for local and remote coverage.
- **Test Scenarios:** Shell children lack all three variables; `workspace_env/2` returns explicit false tuples; remote export inherits the same contract; unrelated launcher variables remain covered by the existing ownership cases; the POSIX shell probe still passes.
- **Verification:** Agent-environment and directly related shell-boundary tests pass.

### U2. Persist a post-crash slogan attention

- **Goal:** Make a newly completed daemon dump visible to the Executor immediately after unexpected VM death.
- **Requirements:** R4
- **Files:** `packaging/npm/aiur-cli/libexec/aiur-engine.sh`, `src/test/aiur_engine_test.exs`
- **Approach:** Read and bound the first `Slogan:` line from the run's daemon dump, include it in the existing crash records, and append one well-formed system alert to the active run's alert feed before continuing the existing reap path.
- **Test Scenarios:** Ordinary, escaped, and oversized slogans produce parseable bounded alert JSON; missing/incomplete dumps do not create a false dump alert; clean stop remains silent; alert-write failure does not block agent reaping.
- **Verification:** Engine shell tests and `bash -n` pass.

### U3. Stop warm-base dump multiplication

- **Goal:** Prevent stale ignored dumps from becoming one copy per ticket workspace.
- **Requirements:** R5
- **Files:** `.gitignore`, `erl_crash.dump`, `src/lib/aiur/workspace/materialize.ex`, `src/test/aiur/workspace/materialize_test.exs`
- **Approach:** Remove the accidentally committed root dump, ignore conventional dump names repository-wide, and clean only ignored dump pathspecs from the staged copy after checkout while retaining tracked content and warm caches.
- **Test Scenarios:** Ignored root and nested dumps are absent; tracked source and ignored `_build` sentinel remain; materialization failure and logs-only reconstruction semantics remain unchanged.
- **Verification:** Workspace materialization tests pass and the root dump is absent from `git ls-files`.

### U4. Publish the evidence classification

- **Goal:** Make the original seven-dump findings and current multiplication analysis durable and reviewable.
- **Requirements:** R1, R6
- **Files:** `docs/measurements/2026-08-16-beam-crash-dump-triage.md`
- **Dependencies:** U1-U3
- **Approach:** Record each original dump's requested fields, distinguish observed facts from inference, link each family to its fix/follow-up, and summarize the current path/hash counts and post-#1521 observation window.
- **Test Scenarios:** The inventory contains all seven original timestamps and process counts; each family has a fixed, linked, or insufficient-evidence disposition; current copied-artifact counts are labeled as paths rather than unique crashes.
- **Verification:** Diff the record against the extracted dump headers, prior workpad, #1499 evidence, and #1429 measurement.

---

## Verification Contract

| Gate | Command / evidence | Covers |
|---|---|---|
| Compile | `cd src && mise exec -- mix compile --warnings-as-errors` | U1, U3 |
| Format | `cd src && mise exec -- mix format --check-formatted` | U1, U3 |
| Scope calculation | `cd src && mise exec -- mix aiur.affected_tests` | U1-U4 |
| Affected tests | Run every emitted invocation with `mix test --max-cases 4` | U1-U3 |
| Shell syntax | `bash -n packaging/npm/aiur-cli/libexec/aiur-engine.sh` | U2 |
| Evidence audit | Re-extract dump headers/hashes and compare the seven rows and family dispositions | U4 |

---

## Definition of Done

- R1-R6 and AE1-AE4 are satisfied without absorbing #1499 or overstating `erl_child_setup` evidence.
- The daemon keeps its durable dump destination, and child environments explicitly lack it and `ERL_LIBS`.
- A completed new daemon dump creates one valid needs-attention alert carrying a bounded slogan.
- Newly materialized workspaces do not inherit ignored crash dumps, while warm build artifacts remain intact.
- The accidentally tracked dump is removed and the triage record timestamps its path/hash snapshot so later growth is not mistaken for the original seven crashes.
- Compile, format, affected tests, shell syntax, self-review, and CI complete against `main`.

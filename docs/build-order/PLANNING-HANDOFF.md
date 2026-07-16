# Build Order Planning Handoff

## Why this document exists

The current agent was asked to stop before finishing publication and hand the
research/decomposition to a successor. This is a planning-only effort. Do not
implement Build Order, run Aiur, merge either draft PR, or dispatch agents as
part of completing this handoff.

The durable outcomes still required are:

1. finish and independently review the Build Order/dashboard decomposition;
2. make every Markdown/JSON/publication artifact agree;
3. validate the frozen pack twice with clean semantic review rounds; and
4. create and reconcile the GitHub issues as the final substantive action.

## Suggested successor goal

Finish the bounded Build Order and shipped-dashboard planning pack on
`build-order-research` without implementing or dispatching the feature. Re-audit
the provisional ticket boundaries against current `origin/main` and the
versioned prototype, reconcile every requirement, dependency, conflict,
publication, and validation artifact, and obtain two successive clean semantic
reviews on one unchanged commit. Only then materialize the exact GitHub issue
graph with the authorized labels and publish a durable receipt; do not stop
until the branch, draft PR, issues, and handoff all reconcile.

## Non-negotiable authority and scope

- Work only in the configured `its-everdred/aiur` GitHub repository.
- Planning and issue materialization are authorized; implementation and an
  Aiur run are not.
- Do not merge `build-order-research` or `aiur-executor-skills` to `main`.
- Do not mutate existing issues #132, #845, #1033, #1034, or #1067. They are
  read-only evidence/disposition references.
- New executable issues receive exactly one `complexity:N` and `model:codex-gpt-5.6-terra`.
  Do not add any `agent:*` label. The skill-delivery issue is human-owned and
  should use `human:todo` only.
- Do not add `Co-authored-by` or other model attribution to commits.
- Use three-to-seven-word commit subjects, commit coherent checkpoints early,
  and push regularly.
- Preserve the bounded feature definition. Nonblocking reliability or
  optimization findings go to `deferred-findings.md`; they do not expand the
  active feature or its ETA.
- A dashboard credential was pasted into chat. It was not used or stored. Do
  not recover it from conversation context or put it in commands/files; the
  owner should rotate it. Current screenshots plus `origin/main` source are
  sufficient for the planning audit.

## Branches and draft PRs

- Planning: `build-order-research`, draft PR
  [#1064](https://github.com/its-everdred/aiur/pull/1064).
- Reusable skills: PR
  [#1065](https://github.com/its-everdred/aiur/pull/1065), final reviewed source
  head `6447f9c193d2322d63f54a58b9c54e0a72d3e98f`, squash-merged to `main` as
  `ed1846c4bc76d4657095da57951a0dbf3e914c3d`.
- Current shipped dashboard baseline: `origin/main` at
  `9849f32963c2a65367bce565b3f5ede3777c218f`.
- Last fully pushed planning checkpoint before the new dashboard re-audit:
  `f4bd87bd4b4231171a34e231b3592dfc3e90c094`.
- This document and the provisional dashboard-ticket edits are in the commit
  containing this handoff.

PR #1064's body must be refreshed after the final immutable pack is known. PR
#1065 is now a landed authority reference for the skill issue; it is no longer
a pending delivery path.

## Read this first

Read in this order:

1. this handoff;
2. [prototype/feature-constraints.md](prototype/feature-constraints.md) and
   [prototype/README.md](prototype/README.md);
3. [06-prototype-capability-audit.md](06-prototype-capability-audit.md) and
   [02-dashboard-design-delta.md](02-dashboard-design-delta.md);
4. [the requirements](../brainstorms/2026-07-12-build-order-requirements.md),
   [technical decisions](05-technical-decisions.md), and
   [state/source-of-truth design](03-source-of-truth-and-state.md);
5. [usage/accounting](04-usage-accounting.md);
6. [dashboard companion history and ownership boundaries](dashboard-companions.md),
   `build-order.json`, and the individual ticket contracts;
7. the BO tickets and
   [the implementation plan](../plans/2026-07-12-005-feat-build-order-dashboard-plan.md);
8. [GitHub publication instructions](github-publication.md),
   `publication.json`, and [the validation report](validation-report.md);
9. [Executor handoff](EXECUTOR-HANDOFF.md) and
   [skill delivery](skill-delivery.md).

Use the repository's `/aiur-build` skill for the decomposition workflow and
the Compound Engineering brainstorm/plan/doc-review/browser skills when they
are available. Re-read their current instructions before acting. The most
valuable additional research is semantic boundary review, not more visual
styling exploration.

## External feature-plan references

The user supplied these prior planning PRs as examples of large-feature
decomposition and durable handoff structure:

- [ethereum-optimism/actions#513](https://github.com/ethereum-optimism/actions/pull/513)
- [its-everdred/aiur#971](https://github.com/its-everdred/aiur/pull/971)
- [its-everdred/aiur#732](https://github.com/its-everdred/aiur/pull/732)

Review them with a document-review lens, but do not treat any one format as a
schema. The reusable pattern is finite acceptance, worker-ready ticket
contracts, explicit typed dependencies/conflicts, phased parallelism, and one
read-first Executor handoff.

## Product decisions already answered

- GitHub support is day one and scoped to the configured repository. Linear
  parity is a separate human-blocked follow-up, not this feature.
- Build Order is read-only. GitHub is truth for roots, membership, ticket
  metadata/lifecycle, and hard blockers. The active Aiur instance is truth for
  runtime progress, current activity, event evidence, and retained usage.
- The page should load current GitHub/Aiur snapshots and remain current through
  daemon-owned LiveView/PubSub updates. Do not add a generic WebSocket ticket;
  the transport already exists and each provider owns generation-safe updates.
- Multiple Build Orders are selected by an explicit GitHub root/parent
  identity; do not mix unrelated epic tickets in one graph.
- Token/cost accounting covers ticket, agent family, backend, exact model,
  provider, current run, and selected build. Claude Remote Control accounting
  is required, not optional.
- Subscription dollar values are API-equivalent token-price estimates, marked
  with `*` and an information popover. Show the actual tier only on an exact
  provider/backend/account-generation join. Never call the estimate billed or
  actual spend.
- Prototype behavior is design evidence, not production architecture. Preserve
  real Analytics, Decision lifecycle, authentication, trusted links, and
  unknown/degraded states; do not copy static data, fake links, browser-local
  mutations, zero-capacity behavior, or inaccessible density.

## What is complete

### Core Build Order decomposition

The Build Order feature remains a coherent **19-ticket / 71-point** graph. The
latest shipped-dashboard audit found no reason to change BO-001..BO-019. In
particular, do not collapse these boundaries:

- BO-016 cached ticket detail;
- BO-019 bounded structured ticket activity/history;
- BO-018 root-independent accessible ticket context;
- BO-011 Build Order relationship/destination adapter; and
- BO-015 Build Order capstone.

The Build Order page itself remains independent of provider accounting and the
existing-page dashboard catch-up.

### Accounting and publication corrections

The pushed planning checkpoint corrected two earlier semantic-review findings:

- provider/source token relationships are versioned, with Claude base input,
  cache creation, and cache read treated as additive for the supported source;
- publication authority rejects Git replacement/graft substitution, proves
  approval precedes receipt both locally and through pinned GitHub comparisons,
  pins API host/version/timeouts, and bounds pagination.

At that checkpoint, the local publication suite reported 102 passing tests and
the companion/publication validator reported zero errors/warnings. Those
results predate the provisional 26–34 ticket edits and are not a final green
claim.

The final reviewed skill source at
`6447f9c193d2322d63f54a58b9c54e0a72d3e98f` passed 134 Python tests, focused
repository skill checks, canonical validation with zero errors/warnings,
diff-check, and clean-clone/GitHub authority review. It was squash-merged to
`main` as `ed1846c4bc76d4657095da57951a0dbf3e914c3d`.

## Why the dashboard delta was reopened

The user showed the shipped dashboard beside the prototype and then showed the
current Fleet-row log modal. Current main is substantially more capable than
the old draft, but the row modal exposes a local workspace path and can render
unknown structured session data as raw JSON. The prototype instead separates:

- row activation → bounded ticket context;
- named Chat action → read-only conversation drawer; and
- structured Logs/activity → ticket context.

The re-audit also found that `RecentMerge.observed_run_id` proves only that a
run observed a GitHub event. It does not prove the run, ticket, or agent caused
the merge, so `Finished this run` needs a typed membership/run-window
projection. Finally, several existing dashboard tickets still bundled
independent backend and UI contracts.

## Current provisional recommendation

The current working judgment is **34 standalone dashboard companions** rather
than the prior 25. This is deliberately more conservative than the first
single-agent audit: a second independent review correctly argued that
current-run outcome qualification and its Units/Commands presentation should
be separate, just as run summary and accounting projection/UI are separate.

The nine provisional additions are:

| ID | Boundary | Cx | Direct prerequisites in current draft |
|---|---|---:|---|
| DASH-026 | bounded sanitized live-conversation projection | 3 | BO-017 |
| DASH-027 | accessible read-only conversation drawer | 3 | DASH-003, DASH-026 |
| DASH-028 | authoritative runtime-capacity UI over existing Slots APIs | 2 | DASH-003 |
| DASH-029 | versioned Codex/Claude headless usage adapters | 3 | DASH-008, BO-017, DASH-018 |
| DASH-030 | exact grouped run/ticket/build usage query | 3 | DASH-011, DASH-024 |
| DASH-031 | authenticated usage/cost summary and drill-down | 4 | DASH-003, DASH-010, DASH-013, DASH-020, DASH-021, DASH-025, DASH-029, DASH-030 |
| DASH-032 | truthful current-run outcome qualification | 3 | DASH-002, DASH-014 |
| DASH-034 | current-run Recent presentation/history preservation | 3 | DASH-003, DASH-007, DASH-032 |
| DASH-033 | existing-dashboard parity capstone | 3 | DASH-001, DASH-003, DASH-005, DASH-007, DASH-015, DASH-022, DASH-027, DASH-028, DASH-031, DASH-034 |

Existing provisional re-scopes:

- DASH-005: per-unit applied pause/resume UI only; capacity moves to DASH-028.
- DASH-008: provider-neutral envelope, validation, relationship registry, and
  exact-money contract only; source adapters move to DASH-029; complexity 3.
- DASH-011: immutable effective-dated exact pricing and token reconciliation
  only; grouping moves to DASH-030; dependency becomes DASH-008; complexity 3.
- DASH-015: authenticated Codex/Claude provider-meter cards only; usage/cost
  moves to DASH-031; dependencies become DASH-003/013/020/021; complexity 3.
- DASH-023: selected GitHub membership-to-accounting integration consumes
  DASH-030/031 rather than the old combined DASH-011/015 contracts.
- DASH-003: row activation remains ticket context; it exposes a separate named
  Chat action seam for DASH-027.
- DASH-007: complete Decision history must remain reachable through Commands
  before DASH-034 changes the Units Recent region.

Under the current draft this is provisionally **34 tickets / 111 points** for
the dashboard companion pack. Do not publish that number until the manifest is
updated and the dependency/serialization graph is recalculated. The current
draft appears to have roughly 70 companion blocker edges and roughly 105 total
publication blocker edges, but those are deliberately marked provisional.

## Highest-value successor review

Review these questions before propagating the draft:

1. **Current-run outcomes:** confirm DASH-032's direct dependency set and exact
   run-window/terminal semantics. `observed_run_id` is never causality. Keep the
   projection separate from DASH-034 unless a reviewer can prove the combined
   ticket remains one coherent acceptance boundary.
2. **Conversation source:** verify BO-017 is the correct propagated identity/
   event prerequisite for DASH-026 and that no browser render path reads
   workspace logs. Unknown structured events must be omitted/count-only, never
   raw fallback content.
3. **Capacity:** inspect current `Aiur.Orchestrator.Slots` before adding backend
   work. Current main already has read/adjust/set APIs and authoritative return
   maps. DASH-028 is intentionally UI-only unless fresh evidence proves a small
   missing backend contract; do not create a speculative scheduler rewrite.
4. **Accounting splits:** challenge DASH-008/029, DASH-011/030, and
   DASH-015/031 for both overlap and missing handoff data. These splits were
   introduced specifically so one UI ticket does not hide multiple provider,
   pricing, query, and security systems.
5. **Capstone boundary:** DASH-033 is existing-page parity and should not depend
   on DASH-023 or make the new Build Order graph wait for accounting. BO-015
   remains the Build Order capstone; the two should serialize only on shared
   browser/closeout surfaces.
6. **Serialization:** recompute symmetric same-pack serialization and one-sided
   declared cross-pack conflicts. The provisional ticket prose is not yet
   fully symmetric, and DASH-031 still needs review against the new DASH-034
   presentation owner.

Explicitly rejected false gaps:

- no generic WebSocket ticket;
- no new ticket-detail backend beyond BO-016/019/018/011;
- no hard-coded Claude conversation link or separate fake Remote Control UI;
- no Analytics placeholder work;
- no minimap, in-graph dependency editing, global search, or all-state
  transcript archive in v1.

## Known incomplete propagation

The new/re-scoped ticket Markdown exists, but the pack is intentionally not yet
internally consistent. At minimum, the successor must update:

- `dashboard-companions.md` and `build-order.json`;
- DREQ-003/005/008/011/015/023 and add DREQ-026..034 in the requirements;
- `02-dashboard-design-delta.md`, `04-usage-accounting.md`, and
  `06-prototype-capability-audit.md`;
- the implementation plan, root README, Executor handoff, and validation
  report;
- every affected ticket's dependencies/serialization/sibling wording;
- publication counts, expected rendered issues, blocker edges, fixtures, and
  tests;
- evidence hashes and all references to the reviewed source and merged skill
  authority;
- PR #1064 body after the immutable result is known.

Most unchanged DASH ticket Markdown still says the OCC predecessor gate is
active. The user has now confirmed the dashboard shipped at the audited main
baseline. Preserve a historical resolution receipt, but remove the gate from
active `external_gate_ids` so tickets are not falsely non-pickable. The current
validator's gate schema accepts only `id/owner/resolution_criteria`; either
extend it safely for a satisfied receipt or record the receipt in durable docs
and remove the active gate. Do not silently leave every DASH issue blocked.

Known draft-specific checks:

- DASH-031's serialization wording was drafted before DASH-032 split into
  backend projection plus DASH-034 UI; reconcile it with DASH-034.
- DASH-033 depends on DASH-034 and is intentionally numbered before one of its
  prerequisites; IDs are logical, not phase order. Renumber only if every
  artifact changes atomically.
- Some existing filenames still contain the older combined title (DASH-005,
  DASH-011, DASH-015). Renaming is optional, but manifest paths and links must
  remain exact.
- `questions.md` contains the safe credential-rotation/access note and should
  be retained or resolved without ever recording the credential.

## Skill pin and publication authority

Pin receipt validation to reviewed source head
`6447f9c193d2322d63f54a58b9c54e0a72d3e98f` and record its landed `main`
commit `ed1846c4bc76d4657095da57951a0dbf3e914c3d` in the planning docs,
`build-order.json`, publication receipt code, validation report, and any
retained publisher. Re-run the reviewed source's canonical validator.

No GitHub issues have been created. The temporary publisher has not performed a
GitHub mutation. Before publication:

1. make manifests/docs/tests/counts exact;
2. run canonical and publication validators, all publication tests, JSON parse,
   pycompile, `git diff --check`, and publisher render/read-only preflight;
3. push one exact candidate;
4. run two successive clean semantic review rounds on the unchanged SHA, with
   product/source-truth, worker-boundary/graph, and publication/authority
   lenses; any finding resets the count;
5. record approval and staging commits according to
   `github-publication.md`;
6. create the exact issues, root subissues, and native blocker graph without
   dispatch labels or protected-issue mutation;
7. requery GitHub, write the immutable receipt, update both draft PR bodies,
   and make the successful reconciliation comment the final GitHub mutation;
8. perform a final read-only audit.

Publication count anchors from the old 25-ticket pack—46 issues and 73 blocker
edges—are stale after this re-audit and must not be used.

## Validation state at handoff

- The repository working tree represented by this handoff is a deliberate WIP
  checkpoint, not an approved publication pack.
- The last pushed pre-delta checkpoint validated, but the new 26–34 ticket set
  has not been propagated to JSON or run through the full suite.
- Clean semantic-pass count is **zero**. Earlier reviews found real accounting
  and publication-authority defects; those were corrected, so they cannot be
  retroactively counted as clean passes.
- Do not create issues from the current manifest until all inconsistencies
  above are resolved.

## Definition of done for the successor

The planning task is complete only when the branch and draft PR contain one
coherent, source-backed requirements/design/ticket/dependency/validation/
handoff pack; the reusable skill delivery is durably referenced; two clean
reviews approve one unchanged candidate; every authorized GitHub issue and
relationship reconciles exactly; no `agent:*` label or protected issue was
mutated; the final receipt is pushed; and a read-only audit proves the live
GitHub graph matches the approved plan.

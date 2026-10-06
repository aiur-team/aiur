---
ticket_id: MP-R1-C8-T1
feature_id: MP-R1
chunk_id: MP-R1-C8
bucket: 1-refactor
title: Commands component facade (`Aiur.Commands`) and external caller migration
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T1, MP-R1-C1-T3, MP-R1-C1-T5]
prior_units: [U6, U2, U4]
prior_boundaries: [DEC #27, EXE #26 (Asks), WEB #34, RUN #18, CLI #31]
prior_features: []
prior_findings: [loose-1-02, loose-1-03]
size_owner: DECISIONS (U8 ledger at 465aca643; re-resolve at ticket start per RC-23 / MP-R1-C11-T2; this ticket adds no lines to decision_store.ex)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C8-T1 — Commands component facade and caller migration

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R1 / C8 (migration step S10, `commands` row).
- **User value:** none visible. The Commands ("Decisions" in code) component gets one
  public entry module, so later features (MP-E2 routing, MP-N6 phone answers, MP-E5
  voice answers) call a stable facade instead of `Aiur.DecisionStore` internals, and
  the MP-R1 checker can enforce that.
- **Deliverable:** a new facade module `Aiur.Commands` (PROPOSED path
  `src/lib/aiur/commands.ex`) that delegates to the existing public functions, all
  callers outside the component switched to it, and the `commands` manifest entry's
  `facades` list set to `Aiur.Commands` plus the public data structs.
- **Non-goals:** no behaviour change; no rename of `Aiur.Decision*` modules; no file
  moves; no change to the answer-delivery path (that is MP-R1-C8-T2); no new
  routing (MP-E2-C2 owns `Aiur.Commands.Routing`); no split of `decision_store.ex`
  (U8 `DECISIONS` owns that).

## Dependencies and blockers

- **Owner gate:** DESIGN-R1 §1 (confirm no runtime change).
- **Predecessors:** MP-R1-C1-T1 (manifest with a `commands` entry), MP-R1-C1-T3 (private
  module rule), MP-R1-C1-T5 (ratchet allowlist and CI wiring). Ticket IDs per the C1–C5
  section of the MP-R1 tickets README.
- **Prior unit:** U6 owns `decision_store.ex` and the `aiur_web` Decision presenters.
  This ticket touches only call sites, not the journal, so it does **not** wait for
  U6's outcome matrix. It must rebase over any U6 PR that renames a public function.
- **Contracts consumed:** `contracts/command-request-and-resolution.md` (MP-E2). Its
  §"ownership" table names new modules under `Aiur.Commands.*`
  (`Routing`, `NativeCapture`); the facade name is chosen so those modules nest under it.
- **May run concurrently with:** C8-T3, C8-T4, C8-T5, C8-T6, C8-T7. Not with C8-T2
  (both edit `decision_store.ex` neighbours and the `commands` manifest entry; T2 goes second).

## Verified starting point (45a290e3)

- Component files: `src/lib/aiur/decision*.ex`, `decision_*/**`, `asks.ex`,
  `asks_store.ex`, `asks_cli.ex`, `supervisor_token.ex` (listed by
  `git ls-tree -r 45a290e3 -- src/lib/aiur | grep -E 'decision|asks|supervisor_token'`).
  `decision_store.ex` is 4,826 lines; its moduledoc calls it "the single public
  Decision application service and serialized writer" (`decision_store.ex:1-28`).
- External call census (`git grep -o -E '(DecisionStore|DecisionQuery|DecisionHistory|DecisionPubSub|Asks)\.[a-z_]+' 45a290e3 -- src/lib ':!src/lib/aiur/decision*' ':!src/lib/aiur/asks*'`):
  `DecisionStore.answer` ×4, `blocked_ticket_ids` ×2, `validate_delivery`,
  `record_delivery`, `record_transport_batch_async`, `request`, `revise`,
  `supersede`, `retry_dispatch`, `recent_decisions`, `open_blocking_decision_ids`,
  `moot`, `handle_revision_follow_up`, `escalate_executor_command`,
  `enrich_attention`, `dismiss`, `deliver_pending_answers`, `defer`,
  `agent_lifecycle`; `DecisionQuery.list/get/counts/default_store`;
  `DecisionHistory.list` ×2; `DecisionPubSub.subscribe` ×3; `Asks.validate_events`, `Asks.open`.
- Files that reference the component from outside (same grep, `-l`): `aiur.ex`,
  `agent_runner/{checkpoint_delivery,queue_drain,tool_executor,turn_callbacks}.ex`,
  `codex/dynamic_tool/errors.ex` (message strings only, lines 168, 177),
  `commands_cli.ex`, `executor_command_cli.ex`, `http_server.ex:8,71`,
  `orchestrator/{dispatcher,event_topics,issue_sync,operator_messages,pause_resume,state}.ex`,
  `repo_base.ex:25,1383`, `events/{id_generator,publisher}.ex` (doc comments only),
  and `aiur_web/{control_center_presenter,presenter,streamdeck_channel,streamdeck_commands}.ex`,
  `aiur_web/controllers/decision_api_controller.ex`, `aiur_web/live/dashboard_live.ex`,
  `aiur_web/operator_control_center/{awaiting_commands,decision_commands,decision_provider,payload_loader,revision_commands}.ex`.
- Upward edges found (L2 → L3, recorded, not fixed here):
  - agent-runner → commands: `agent_runner/tool_executor.ex:80-84` (default
    `&DecisionStore.request/2`, `agent_lifecycle/3`, `enrich_attention/2`,
    `DecisionAttention.open_with_decision/6`, `resolve/2`),
    `agent_runner/queue_drain.ex:243,284` (`validate_delivery`, `record_delivery`),
    `agent_runner/checkpoint_delivery.ex:25,41,68`.
  - workspace → commands: `repo_base.ex:1383` (`Asks.validate_events/1`).
- Existing tests: `src/test/aiur/decision_store_test.exs`, `decision_dispatch_test.exs`,
  `decision_expiry_test.exs`, `src/test/aiur/agent_runner/queue_drain_test.exs`,
  `src/test/aiur_web/live/dashboard_live_test.exs`.

## Chosen design

- **Facade, not rename.** `Aiur.Commands` contains only `defdelegate` lines (plus
  `@moduledoc` and `@spec` copied from the delegate targets). Renaming 90+
  `Aiur.Decision*` modules would touch every test and violate the behaviour-only
  scope; the manifest makes the old modules private instead.
- **Facade surface** (exactly the census above, nothing new):
  `request/2`, `answer/2`, `revise/2`, `supersede/2`, `moot/2`, `dismiss/2`,
  `defer/2`, `retry_dispatch/2`, `escalate_executor_command/2`,
  `handle_revision_follow_up/2`, `enrich_attention/2`, `agent_lifecycle/3,4`,
  `blocked_ticket_ids/0,1`, `open_blocking_decision_ids/1,2`,
  `deliver_pending_answers/1,2`, `validate_delivery/1,2`, `record_delivery/1,2`,
  `record_transport_batch_async/3,4`, `recent_decisions/…`, `query_list/…`
  (→ `DecisionQuery.list`), `query_get/…`, `query_counts/…`, `default_store/0`,
  `history/…` (→ `DecisionHistory.list`), `subscribe/…` (→ `DecisionPubSub.subscribe`),
  `validate_asks/1` (→ `Asks.validate_events/1`), `open_asks/…` (→ `Asks.open`).
  The implementer copies the arities from the targets at the implementation head; a
  target that no longer exists is removed from this list, never re-created.
- **Public data types stay public:** `Aiur.Decision`, `Aiur.DecisionAnswer`,
  `Aiur.DecisionRevision`, `Aiur.DecisionEvent`, `Aiur.DecisionArtifact` are listed as
  facades in the manifest (structs pattern-matched by surfaces).
- **Manifest change:** `commands.facades = ["Aiur.Commands", <the five structs>,
  "AiurWeb.DecisionApiController" (route target)]`; `status: core`.
  **Correction to component-map.md:** `commands` is required, not "optional in
  principle". The dispatch gate fails closed when the store cannot be read
  (`orchestrator/dispatcher.ex:480-491`: `{:error, :store_unavailable}` →
  `blocked_ticket_ids: :unavailable`, which holds every new dispatch). An absent
  component would therefore stop all dispatch. Making Commands removable needs a
  separate decision on "not installed ≠ unavailable" (RQ-C8-1).
- **Allowlist entries** (C1 ratchet format, reason text included in the PR):
  agent-runner → `Aiur.Commands` (four files above) and workspace → `Aiur.Commands`
  (`repo_base.ex`). They become facade references instead of private-module
  references, so the private-module violation count drops; the layer violation stays
  allowlisted until MP-E2 introduces the agent-side port.

## Implementation steps

1. Add `src/lib/aiur/commands.ex` (≈120 lines) with the delegates above.
2. Replace each external reference with `Aiur.Commands.<fn>`; keep default-argument
   injection seams intact (e.g. `tool_executor.ex:80` becomes
   `Keyword.get(opts, :decision_requester, &Aiur.Commands.request/2)`).
3. `http_server.ex:71` keeps passing the store **name** (`DecisionStore` is a process
   name, not a call); change it to `Aiur.Commands.default_store()` only if that returns
   the same atom (verify at head).
4. Leave doc-comment mentions in `events/*.ex` and error message strings in
   `codex/dynamic_tool/errors.ex` unchanged (they are text, the checker ignores them).
5. Update `components.json` `commands` entry (facades, status) and the allowlist; run
   the checker and record the before/after violation count in the PR body.

## Non-happy paths

- **Store down:** every delegate keeps the target's `catch :exit` behaviour
  (e.g. `blocked_ticket_ids/1` returns `{:error, :store_unavailable}`,
  `decision_store.ex:451-455`). A facade must not add its own `try`.
- **Arity drift:** a missing `defdelegate` arity is a compile warning; CI runs
  `--warnings-as-errors` through `make lint` — verify at head, otherwise add a facade
  test that calls every exported function's arity via `function_exported?/3`.
- **Privacy:** no payload changes; nothing new is logged.

## Compatibility and rollout

No config, no migration, no flag. Old module names keep working, so a revert is a
plain revert of the PR (the allowlist reverts with it).

## Verification

- New `src/test/aiur/commands_facade_test.exs`:
  - `test "every facade function delegates to an exported target"` — for each
    `{fun, arity}` in `Aiur.Commands.__info__(:functions)`, assert the mapped target
    `function_exported?/3` is true. **Future-regression guard; passes on main once the
    facade exists; not counted as covering a behaviour change.**
  - `test "blocked_ticket_ids/1 through the facade reports :store_unavailable for a dead store"`
    — start nothing under a fresh name, assert
    `Aiur.Commands.blocked_ticket_ids(:no_such_store) == {:error, :store_unavailable}`.
- Mutation check: the meaningful assertion is the checker's. With the facade migration
  reverted for one file (e.g. `queue_drain.ex` back to `DecisionStore.validate_delivery`),
  `python3 scripts/check-components.py` must report one new private-module violation
  over the ratchet baseline and exit non-zero. Record the command and output in the PR body.
- Existing suites unchanged and green:
  `env -C src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/decision_store_test.exs test/aiur/decision_dispatch_test.exs test/aiur/agent_runner/queue_drain_test.exs test/aiur_web/live/dashboard_live_test.exs test/aiur/commands_facade_test.exs`
  (temporary `HOME` keeps the real `~/.aiur/github-budget/agent-token` untouched).
- `make -C src fmt-check lint`; `python3 scripts/check-components.py`.
- Manual: none required beyond U9's foreground acceptance — no rendered change.

## Completion and handoff

- [ ] `Aiur.Commands` exists; no reference to a non-facade commands module outside the component (checker).
- [ ] Violation count ≤ baseline; allowlist entries carry reasons.
- [ ] `component-map.md` correction (commands required) applied by the C11 refresh.
- **Docs:** none (no user-facing surface; AGENTS.md "Docs ship with the change" exempts internal refactors).
- **Dependents:** MP-R1-C8-T2; MP-E2-C2 (routing module nests under `Aiur.Commands`);
  MP-N6, MP-E5 answer paths call the facade. Plan-refresh row PR-06.

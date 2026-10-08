---
ticket_id: MP-E8-C5-T04
feature_id: MP-E8
chunk_id: MP-E8-C5
bucket: 2-platform
title: Skill and prompt guidance for categories and estimates
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C5-T03, MP-E8-C6-T04, MP-E8-C7-T03]
complexity: 2
design_gate: DESIGN-E8
design_signoff_items: []
owns_edge_cases: []
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C5-T04 — Skill and prompt guidance for categories and estimates

## Identity and outcome

- Bucket 2, feature MP-E8 (home page "Continuous build history"), chunk C5
  (epics).
- **User value:** about 90 % of history has no epic signal (chunks.md C5,
  baseline §5). Without guidance, new tickets keep landing in the Unsorted
  column. With it, the agents that plan and file tickets put each new ticket in
  its epic column the moment it exists, and they change a planned estimate only
  with a recorded reason (E8-D7, E8-D9).
- **Deliverable:** text edits only, plus one guard test file:
  1. A short "home-page epic" rule next to the existing ticket-creation rule in
     each skill doc that files tickets (list in "Chosen design").
  2. An estimate-override rule in the two planning skills (`aiur-build`,
     `aiur-run`).
  3. One paragraph in `website/docs-app/skills.md`.
  4. PROPOSED `src/test/aiur/build_history_guidance_skill_test.exs`, which
     checks that every documented command is accepted by the real engine
     argument checks (`cmd_epic`, `cmd_feature`, `cmd_ticket`) and that every
     documented agent tool and argument exists in `DynamicTool.tool_specs/0`.
- **Non-goals:**
  - No CLI, store or resolver code. `aiur epic set` is C5-T03, `aiur feature`
    is C6-T04, `aiur ticket estimate` is C7-T03.
  - No change to `src/prompts/shared-agent-instructions.md` (see "Decisions
    made without the owner", item 1).
  - No new label family, no GitHub writes, no automatic tagging (plan §10
    item 14: "no silent tagging").
  - No reference docs for the commands. `reference/cli.md` is owned by C5-T03,
    C6-T04 and C7-T03; C12-T07 assembles the concepts page.

## Dependencies and blockers

- **DESIGN-E8.** No sign-off item applies; the rule follows the design's epic
  keys (`GENERAL`, J:96) and its override cue (J:224, 857, 1426).
- **MP-E8-C5-T03** (hard). Its ticket file (§1, §4.5, §4.6, §10) supplies:
  - CLI `aiur epic set <epic> <ids…> [--source cli|backfill-agent] [--as <who>] [--json]`,
    `aiur epic clear <ids…>` and `aiur epic show [<ids…>]`, parsed by engine
    `cmd_epic`. The engine refuses `--source agent:<n>` with exit 64 (its V-26).
  - Agent tool `aiur_set_epic` (`epic`, `ids` default = own ticket, up to 200,
    `clear`, `backfill`). The daemon records `actor: agent:<bound ticket>`.
    This is the only path from an issue workspace: the workspace environment
    scrubs the release node, so the CLI cannot reach the daemon (its §3.4).
  - General epic keys only (its decision 3); `unsorted` is not settable; an
    unknown key is rejected "with the list of known keys" (its acceptance list).
  This ticket teaches those exact names, so it cannot merge first.
- **MP-E8-C6-T04** (hard). Supplies `aiur feature create|add|remove|also|baseline|show`
  (engine `cmd_feature`; `add` refuses a ticket owned by another feature unless
  `--move`; `--source` accepts only `backfill-agent`) and the agent tool
  `aiur_feature` (no `baseline` for agents).
- **MP-E8-C7-T03** (hard). Supplies `aiur ticket estimate <id> <hours> --reason <text> [--by <who>] [--json]`
  and `--clear --reason` (engine `cmd_ticket`; exit 64 on a missing or blank
  reason; reason 1..500 characters, one line) and PROPOSED
  `Aiur.BuildOrder.Estimates.default_hours/1` (`%{1 => 1, 2 => 2, 3 => 4, 4 => 7, 5 => 11}`).
  It deliberately adds no agent tool (its decision 4).
- **MP-E8-C6-T03** (soft, read only). Its rule "every `build-order` root becomes
  a feature, and a root's `build-lane:` slugs become feature epics" is what lets
  aiur-build members get an epic with no extra command. It reads the
  `build-lane:<slug>` label of each sub-issue of the root and keys the epic
  `f-bo-<root>-<lane>`. If C6-T03 changes that rule, the aiur-build paragraph
  here changes with it.
- **Interfaces this ticket needs from its predecessors (see "Interface
  requests").** The tool's unknown-epic error lists the valid keys (settled
  2026-10-08 by C5-T03); the predecessors keep their argument checks in the
  engine so this test can call them.
- **May run concurrently with:** everything after its three predecessors. It
  edits only skill markdown, `skills.md` and one new test file.
  **File overlap:** C12-T07 also lists `skills.md`. This ticket writes the
  paragraph; C12-T07 links to it and must not add a second copy (AGENTS.md:
  "link to it rather than restating it").
- **Successors:** C12-T07 (documentation), C13-T04 (the backfill runbook
  reuses the same rules; it runs in a workspace, so it uses `aiur_set_epic` and
  `aiur_feature` with `backfill`, per C5-T03's interface note).

## Verified starting point (`58854d4c8`, `/home/everdred/github/everdred/aiur-worktrees/runtime`)

All paths below exist at the base SHA unless marked PROPOSED.

- **Where tickets are filed today, and the rule each doc already states.**
  Every doc that can create a ticket states the "same creation request" rule,
  and a test locates it by that marker:
  - `.claude/skills/aiur-agent/conventions.md:24-46` "Ticket creation state".
    This is the issue-worker path (out-of-scope findings, `:48-63`).
  - `.claude/skills/aiur-run/SKILL.md:228-234` (Executor filing).
  - `.claude/skills/aiur-run/references/executor.md:81-89` (Executor filing,
    long form).
  - `.claude/skills/aiur-meta/SKILL.md:264-268` (meta findings).
  - `.claude/skills/aiur-build/SKILL.md:218-237` "Optional GitHub promotion"
    and `.claude/skills/aiur-build/references/planning-contract.md:49-61`
    "Executor-owned promotion".
- **The guard test to copy.** `src/test/aiur/aiur_agent_skill_test.exs`:
  - `:39-46` `@creation_rule_marker "same creation request"` and
    `@creation_rule_docs` (the five docs above, minus planning-contract.md);
  - `:269-308` "every filing path teaches a disposition the gh guard actually
    accepts": it pulls backticked tokens out of the marked blocks and runs them
    through the real `gh` wrapper, then checks the wrapper still refuses bad
    input;
  - `:774-797` `creation_rule_blocks/1` splits a doc into paragraphs, keeps
    those that carry the marker, and joins a trailing list when the paragraph
    ends in a colon; `:841` `one_line/1`.
  This is exactly the shape needed here: a rule located by a marker, and its
  commands checked against the real implementation instead of a copy.
  **Marker hazard:** any new paragraph that contains "same creation request"
  becomes a creation-rule block, and the test then runs each of its backticked
  label-shaped tokens through the guard alone (`:294-296`). A token such as
  `build-lane:runtime` carries no disposition and is refused, so the existing
  test fails. The new paragraphs must not use that phrase.
- **The engine-argument harness to reuse.** `src/test/aiur_engine_test.exs:1388-1401`
  sources the engine with a stubbed `run_control_rpc` (`echo "RPC:$1"`) and
  asserts the RPC line on success and exit 64 on a usage error.
  `run_sourced_engine/2` is private at `:1737` (with a node-isolation guard at
  `:1738-1748` so a test never reaps a live BEAM); a second copy already exists
  at `src/test/aiur/regression/engine_control_test.exs:925`. C5-T03, C6-T04
  and C7-T03 put their argument checks in this engine (`cmd_epic`,
  `cmd_feature`, `cmd_ticket`), so this harness is "the real parser".
- **The agent tool list.** `src/lib/aiur/codex/dynamic_tool.ex:15` `@handlers`
  and `:35-38` `tool_specs/0` (each spec has `"name"` and `"inputSchema"`, for
  example `dynamic_tool/ticket_state.ex:46,67-69` with
  `"additionalProperties" => false`). C5-T03 and C6-T04 add `aiur_set_epic` and
  `aiur_feature` here.
- **Who reads which skill.** `src/lib/aiur/agent_skills.ex:43`
  `@aiur_issue_worker_skills ~w(aiur-agent aiur-debug design-import)` are copied
  into every ticket workspace on any repository. `aiur-build`, `aiur-run` and
  `aiur-meta` are Executor skills (`website/docs-app/skills.md:45-59`). So an
  issue worker sees only the aiur-agent rule, and it acts through dynamic
  tools, not the `aiur` CLI (C5-T03 §3.4).
- **The `epic` naming hazard.** Two existing meanings of "epic" are not the
  MP-E8 epic:
  - `src/lib/aiur/orchestrator/issue_sync.ex:489-492` `parked_marker_label?/1`
    treats any label starting `epic:` as deliberate parking; such a ticket is
    never rewritten to `agent:todo`.
  - The exact `epic` label marks an `Epic:` container that stays undispatched
    (`executor.md:84-86`, `conventions.md:35-37`).
  An agent that "gives a ticket an epic" by adding an `epic:infra` label parks
  the ticket. The guidance must forbid that by name.
- **Lanes today.** `src/lib/aiur/build_order/metadata.ex:47-56` parses
  `build-lane:<slug>`; `:109-119` accepts any slug matching
  `^[a-z0-9][a-z0-9-]{0,63}$` (`:119`) and says lanes are "a planner's choice …
  so a build order may define its own epics". `aiur-build` members carry `lane`
  (`planning-contract.md:24-35`), and the pack's `label_projection.workstreams`
  maps each lane to its `build-lane:` label
  (`references/build-order.example.json:14-19`, `"workstreams"` at `:16-19`). The lane-choice rule already
  exists: `references/decomposition-workflow.md:202-207` ("keep the set small
  (3–6), fold a one-ticket lane into its nearest neighbor"). The manual
  promotion text (`aiur-build/SKILL.md:231-236`) names only the todo label, not
  the `build-lane:` label or the sub-issue link that C6-T03 reads.
- **Complexity guidance today.** `aiur-build/SKILL.md:107-116` "Complexity
  points measure size and uncertainty only" (1–5).
  `aiur-agent/complexity-routing.md:1-15` treats the label as a starting
  hypothesis for model choice. Neither mentions hours.
- **The per-turn prompt.** `src/lib/aiur/prompt_builder.ex:11-13` embeds
  `src/prompts/shared-agent-instructions.md` (266 lines) at compile time and
  prefixes it to every issue-worker turn. It is the only file in `src/prompts/`.
  There is no planner prompt. `aiur-agent/SKILL.md:77-87` limits the per-turn
  prompt to protocols that fire between turns.
- **Design values the guidance must agree with** (`design-source/assets/build.js`):
  - `GENERAL` (J:96): keys `bugs`, `design`, `infra`, `docs`; `unsorted`
    (J:116) is the resolver's last answer, not a choice.
  - Feature epic keys look like `f-khala-srv` (J:105-111, `addF` J:117-121).
  - `EST = [1, 2, 4, 7, 11]` (J:94) hours by complexity.
  - The override reason is shown verbatim: as the `title` of the
    `.bd-q.ovr` "estimate overridden" cue (J:857) and as a `.bm-cue` line in
    the modal (J:1426). The design's sample reason (J:224) is "Planner
    override · needs 3 illustration rounds with design review — bumped from
    2h to 7h".

## Chosen design

Smallest complete change: put one rule beside the rule agents already follow
when they file a ticket, and test it the way the creation rule is tested.

### Rule A — home-page epic (all filing docs)

Marker phrase: **"home-page epic"** (unique; no doc uses it today). Each doc gets
one paragraph that carries the marker. It is a separate paragraph (blank line
before and after) and never contains "same creation request" (see the marker
hazard above). Two forms, one per caller.

**Executor form** (aiur-run, aiur-meta, aiur-build; these run where the CLI
reaches the daemon):

> **Give every new ticket a home-page epic.** After `gh issue create` returns the
> number, run `aiur epic set <epic> <ids…>` once per epic; one call takes up to
> 200 ids. `aiur epic set` takes a general epic key only (the defaults are
> `bugs`, `design`, `infra`, `docs`; a repository can change them). An unknown
> key is refused with the list of valid keys, so read that error rather than
> guess. A ticket that belongs to a feature gets its epic from the feature: run
> `aiur feature add <slug> <ids…>` instead. If you cannot tell which epic fits,
> set none: the ticket shows as Unsorted, which is true, and a wrong column is
> not. **Never** express an epic as a label: `epic:<name>` parks the ticket and
> `epic` marks an undispatched container. The epic is local Aiur state, so a
> failed `aiur epic set` never hides the ticket; report the failure and
> continue.

**Issue-worker form** (aiur-agent `conventions.md` only). The CLI cannot reach
the daemon from a workspace (C5-T03 §3.4), so the worker uses the tools:

> **Give every finding you file a home-page epic.** After `gh issue create`
> returns the number, call `aiur_set_epic` with `epic` and `ids` (the new
> number). Aiur records you as the actor. Use a general epic key only; an
> unknown key is refused with the list of valid keys. If the finding belongs to
> a feature, call `aiur_feature` to add it there instead. If you cannot tell
> which epic fits, set none: the ticket shows as Unsorted, which is true, and a
> wrong column is not. **Never** express an epic as a label: `epic:<name>` parks
> the ticket and `epic` marks an undispatched container. If the tool is not in
> your tool list, or it reports that build history is unavailable, skip the
> step and say so in the workpad; never block filing on it.

Per doc:

| Doc | Audience | Form and variation |
| --- | --- | --- |
| `aiur-agent/conventions.md` (new paragraph after `:46`) | issue worker filing a finding | Issue-worker form. |
| `aiur-run/SKILL.md` (after `:234`) | Executor | Executor form, short; points to `references/executor.md` for detail. |
| `aiur-run/references/executor.md` (after `:89`) | Executor | Executor form, full, plus: when promoting or retro-classifying many tickets, group the ids by epic and make one call per epic; if `aiur feature add` refuses a ticket owned by another feature, use `--move` only when the ticket really changed feature. |
| `aiur-meta/SKILL.md` (after `:268`) | meta findings | Executor form, short. Meta findings are usually `infra` or `bugs`. |
| `aiur-build/SKILL.md` (in "Optional GitHub promotion", after `:236`) | Feature Planner and promoting Executor | Rule A′ below, then one sentence: other tickets follow the Executor form. |
| `aiur-build/references/planning-contract.md` (after `:61`) | same | One sentence that points at the SKILL.md paragraph. |

### Rule A′ — Build Order members (aiur-build only)

Members of a Build Order need no `aiur epic set` call. The root becomes a
feature and each member's lane becomes its feature-epic column (C6-T03). C6-T03
reads the lane from the `build-lane:<lane>` label of each sub-issue of the
root, so the paragraph tells the promoting Executor and the planner:

- each promoted member carries its `build-lane:<lane>` label from the pack's
  `label_projection.workstreams` and is a sub-issue of the root; a member
  without either shows in no feature column;
- choose lanes by the existing rule (`references/decomposition-workflow.md:202-207`);
  the lane names become the column names an operator scans. Do not restate
  that rule;
- tickets filed outside the root's sub-issues (ad hoc, findings) still follow
  Rule A.

### Rule B — estimates (aiur-build and aiur-run only)

Marker phrase: **"estimate override"**. Text:

> **Leave the estimate alone unless you have a strong, specific reason.** A
> planned ticket's estimate comes from its complexity (1, 2, 4, 7, 11 hours for
> `complexity:1`–`5`). If the work is bigger or more uncertain than its label,
> fix the complexity label or split the ticket; that is not an estimate
> override. Override only for duration that complexity does not capture, such as
> review rounds with a person, a wait on outside work, or a long data migration:
> `aiur ticket estimate <id> <hours> --reason "<cause> — from <old>h to <new>h"`.
> The reason is shown to the operator word for word on the planned card and in
> the ticket modal, so write one line (at most 500 characters) they can check.
> To undo an override, use `aiur ticket estimate <id> --clear --reason "<why>"`.

Issue workers do not get Rule B: E8-D7 gives the override to "the Executor's
planning agent", and C7-T03 adds no agent tool (its decision 4).

### Why skills and not the per-turn prompt

The shared prompt is paid on every turn of every worker, and its own policy
(`aiur-agent/SKILL.md:77-87`) keeps only between-turn protocols there. Filing a
ticket is a rare action that already sends the worker to `conventions.md`.

### The guard test

PROPOSED `src/test/aiur/build_history_guidance_skill_test.exs`, modelled on
`aiur_agent_skill_test.exs:269-308`:

- `@epic_rule_marker "home-page epic"` and `@epic_rule_docs` = the six docs in
  the Rule A table.
- `@estimate_rule_marker "estimate override"` and `@estimate_rule_docs` =
  `aiur-build/SKILL.md`, `aiur-run/SKILL.md`.
- A block finder copied from `creation_rule_blocks/1` (paragraph split, marker
  filter, colon-joins-list), parameterised by marker.
- A command extractor: backticked spans starting `aiur epic `, `aiur feature `
  or `aiur ticket estimate `, with placeholders filled from one fixed table
  (`<epic>` → `infra`, `<ids…>` → `101 102`, `<id>` → `101`, `<slug>` →
  `docs-site`, `<hours>` → `7`, `"<cause> — from <old>h to <new>h"` →
  `"needs design review — from 2h to 7h"`, `"<why>"` → `"review done"`).
  A span with a placeholder not in the table fails the test, so a new
  placeholder cannot slip through unchecked.
- Each command, with `aiur ` dropped, runs as `cmd_epic …`, `cmd_feature …` or
  `cmd_ticket …` in the sourced engine with `run_control_rpc() { echo "RPC:$1"; }`,
  as `aiur_engine_test.exs:1388-1401` does. Accepted means exit 0 and an
  `RPC:Aiur.AgentControlCLI.` line. No copy of the parsing rules lives in the
  test.
- `run_sourced_engine/2` is copied from `aiur_engine_test.exs:1737` with its
  node-isolation guard intact (a third copy; see "Decisions made without the
  owner", item 7).
- A tool extractor for the issue-worker block: each backticked `aiur_*` name
  must be in `Aiur.Codex.DynamicTool.tool_specs/0`, and each backticked
  argument the block names for it (`epic`, `ids`) must be a key of that spec's
  `"inputSchema"["properties"]`.

## Implementation steps

1. Confirm the three predecessors at the current base: the engine functions
   (`cmd_epic`, `cmd_feature`, `cmd_ticket`), their verbs and flags, the id
   syntax they accept (C5-T03's V-25 accepts `12` and `'#13'`), and the tool
   names and input properties (`aiur_set_epic`, `aiur_feature`). Use their
   names in the text if they differ from this ticket; this ticket follows them.
2. Write the test file first ("Verification" names its cases). Run it: T1 and
   T3–T7 fail with "no longer states the home-page epic rule" or "… estimate
   override rule", and T2 fails with "no command found".
3. Add Rule A to the six docs in the table, using the per-doc form.
4. Add Rule A′ to `aiur-build/SKILL.md` and the pointer sentence to
   `planning-contract.md`.
5. Add Rule B to `aiur-build/SKILL.md` (after the complexity list, `:107-116`)
   and to `aiur-run/SKILL.md` (beside Rule A).
6. Add one paragraph to `website/docs-app/skills.md` after `:43` (end of the
   agent-workspace notes, before "## Executor skills" at `:45`): "Agents that
   file or plan tickets give each one a home-page epic: issue workers call the
   `aiur_set_epic` or `aiur_feature` tool; the Executor runs `aiur epic set` or
   `aiur feature add`. Only the Executor changes a planned estimate, with
   `aiur ticket estimate … --reason`. See [CLI reference](/reference/cli)." No
   second copy of the rules.
7. Run `aiur_agent_skill_test.exs` as well: the new paragraphs sit next to the
   creation-rule blocks and must not change them.
8. Run the commands in "Verification". Do the revert check and record it in the
   PR body.

## Non-happy paths

| Case | Input | Expected behaviour of the guidance | Proven by |
| --- | --- | --- | --- |
| `epic:` label confusion | An agent reads "give it an epic" | The block names `epic:<name>` and `epic` as forbidden and says why | T3 |
| Epic key not known to the agent | Repo overrides the defaults (C5-T01 config) | The block says an unknown key is refused with the list of valid keys and tells the agent to read that error; it names only the defaults, labelled as defaults | T4 |
| Unknown epic typed anyway | `aiur epic set infrastructure 101` | The engine passes it (the shape is valid); the daemon refuses it with the valid keys (C5-T03 acceptance list). Nothing is written; the ticket stays Unsorted | C5-T03's tests own the refusal; T4 asserts the "list of valid keys" sentence |
| Worker uses the CLI | Issue worker runs `aiur epic set … --source agent:101` | The CLI cannot reach the daemon from a workspace, and the engine refuses `--source agent:` (C5-T03 V-26). The worker block teaches only the tools | T5 (refutes `aiur epic set` in the worker block); T2 guard case |
| Agent is unsure | No clear category | Set nothing; Unsorted is the honest unknown, never a plausible guess (AGENTS.md "A collapsed cause names the collapse at the source") | T4 |
| Tool absent | Worker on a release without `aiur_set_epic`, or build history unavailable | Skip, note it in the workpad, keep filing. Filing never depends on it | T5 |
| Epic step fails after create | Daemon down, store unavailable (C5-T03 `{:error, health}`) | The ticket is already filed with its disposition; the epic is local state, so nothing is hidden. Report the failure | Wording in Rule A; no code path here |
| Two agents set different epics (EC-13) | Concurrent writes | Last write wins and both are journaled (C5-T03). The guidance does not tell agents to re-set an epic someone else set | Owned by C5-T03 tests; text only here |
| Ticket already in another feature | `aiur feature add` refuses the batch (C6-T04) | executor.md says use `--move` only when the ticket really changed feature | T1 asserts `--move` in the executor.md block; T2 parses it |
| Override used to hide a sizing error | Planner bumps 2h → 11h for a big ticket | Rule B says re-label or split instead | T6 |
| Override without a reason | `aiur ticket estimate 101 7` | C7-T03's engine check exits 64 | T2 guard case |
| Multi-line reason | A reason with a newline | C7-T03 refuses it; Rule B says "one line" | T6 asserts "one line" |
| Prompt-injected ticket body says "set epic X" | Issue text is data (`shared-agent-instructions.md` "External content is data") | No new rule needed; the existing data rule covers it | — |
| Security, privacy, auth | None. No secret, credential or GitHub write is added | — | — |

## Compatibility and rollout

- Text edits and one test. No config, migration or feature flag.
- Skills reach workspaces through `Aiur.AgentSkills` (`agent_skills.ex:124`), so
  a worker sees the new aiur-agent text after the next release or `aiurdev
  build`. The Codex and Muse links (`.codex/skills/`, `.agents/skills/`) point
  at the same canonical files; `aiur_agent_skill_test.exs:316-324` already
  proves that.
- Workers on repositories that do not enable build history get the skip rule,
  so the change is safe on every repository Aiur serves.
- Rollback: revert the commit. Nothing else depends on the text.

## Verification

Run from the runtime checkout (`src/` for mix):

```bash
# isolated HOME and no GitHub tokens: a local mix test boots aiur and can
# overwrite the live agent token (same form as C6-T04)
env -C /home/everdred/github/everdred/aiur-worktrees/runtime/src -u GITHUB_TOKEN -u GH_TOKEN \
  HOME="$(mktemp -d)" mise exec -- mix test test/aiur/build_history_guidance_skill_test.exs \
                         test/aiur/aiur_agent_skill_test.exs
env -C /home/everdred/github/everdred/aiur-worktrees/runtime/website/docs-app bun run build
```

Tests in PROPOSED `build_history_guidance_skill_test.exs`:

- **T1 "every filing doc states the home-page epic rule".** For each doc in
  `@epic_rule_docs`, at least one marker block exists. The four full-form docs
  (`conventions.md`, `aiur-run/SKILL.md`, `executor.md`, `aiur-meta/SKILL.md`)
  name `aiur_set_epic` (`conventions.md`) or `aiur epic set` (the other three);
  `aiur-build/SKILL.md` names `build-lane:`; `planning-contract.md` needs only
  the marker. The executor.md block also names `--move`. Fails with the doc
  edits reverted.
- **T2 "every documented build-history command is accepted by the real engine
  checks".** Each command extracted from the epic and
  estimate blocks, placeholders filled, run as
  `cmd_epic|cmd_feature|cmd_ticket …` with the stubbed `run_control_rpc`, exits
  0 and prints an `RPC:Aiur.AgentControlCLI.` line. Each documented tool name is
  in `DynamicTool.tool_specs/0`, and each documented argument is in its input
  properties. Then the guard cases, so the test cannot pass against a check
  that accepts everything: `cmd_epic set infra` (no ids),
  `cmd_epic set infra 101 --source agent:101`, `cmd_ticket estimate 101 7` (no
  `--reason`) and `cmd_epic list` (unknown verb) each exit 64. The test also
  asserts that at least one command was extracted per CLI, so an empty
  extraction cannot pass. Fails when a doc teaches a verb, flag or tool
  argument that does not exist.
- **T3 "no epic block teaches an epic label".** In every epic block, the only
  backticked tokens that start with `epic` are `epic:<name>` and `epic`, and
  both sit in one sentence that contains "Never" and "parks"; each full-form doc
  has that sentence. Fails if the
  sentence is removed, or if a writer adds "label it `epic:infra`".
- **T4 "the epic rule leaves an unknown category unset".** The block in each full-form
  doc contains "Unsorted", "set none" and
  "list of valid keys". Fails if a writer replaces the "set none" sentence with
  a default such as "otherwise use `infra`".
- **T5 "the issue-worker rule uses the tools and never blocks filing".** The
  `conventions.md` block names `aiur_set_epic` and `aiur_feature`, contains the
  skip-and-workpad sentence ("never block filing"), and does not contain
  `aiur epic set` or `--source`. Fails if the worker is taught the CLI.
- **T6 "estimate overrides need a strong reason and are not resizing".** Both
  `@estimate_rule_docs` blocks name `aiur ticket estimate`, `--reason`,
  "strong", "one line" and the "fix the complexity label or split" sentence.
  The hours list in the block equals
  `Enum.map(1..5, &Aiur.BuildOrder.Estimates.default_hours/1)` (C7-T03), so the
  numbers are not typed twice. Fails if the doc and the table disagree.
- **T7 "skills.md points at the commands once".** `website/docs-app/skills.md`
  names `aiur_set_epic`, `aiur epic set` and `aiur ticket estimate` exactly
  once each.

**Revert check (AGENTS.md).** In a worktree, revert only the markdown hunks
(`git diff` shows only `.claude/skills/**` and `website/docs-app/skills.md`;
`git status --porcelain` shows nothing else), run the test file, confirm T1 and T3–T7
fail and T2 fails with "no command found in the home-page epic blocks"; restore
and confirm all pass. Put the exact commands and one line per test in the PR
body.

**Manual check.** Not a UI change, so the AGENTS.md TUI recipe does not apply.
In the Executor checkout with `aiurdev --bg` running and build history enabled,
follow the aiur-run text literally once: `aiurdev epic set infra <a real id>`,
then `aiurdev epic show <id> --json`, and confirm the override has source
`cli:$USER` and actor `cli:$USER`. Then run `aiurdev ticket estimate <id> 3 --reason
"manual check — from 2h to 3h"` and the `--clear --reason "manual check done"`
form. After `aiurdev build`, open one new ticket workspace and confirm that its
`.claude/skills/aiur-agent/conventions.md` contains the "home-page epic"
paragraph (the skill shipped). The worker tool path itself is proven by C5-T03
V-27/V-28 and C6-T04 V-T1/V-T4. Record the transcript in the PR.

## Pixel parity

Not applicable: this ticket renders nothing. The design elements it describes
in words are checked where they are drawn:

- the epic columns from `GENERAL` (J:96) and feature epics (`addF`, J:117-121):
  C9 board tickets, through the C1-T02 side-by-side runner;
- the `.bd-q.ovr` "estimate overridden" cue (J:857) and the `.bm-cue` reason line
  (J:1426): C7-T03 and the C11 modal tickets.

The only design-derived values in this ticket are text: the epic keys, the
`EST` hours and the override-reason shape (J:224). T2 and T6 tie them to the
code that owns them rather than to copies.

## Completion and handoff

- [ ] Rule A in all six docs, Rule A′ in aiur-build, Rule B in aiur-build and
      aiur-run, one paragraph in `skills.md`.
- [ ] T1–T7 pass; the revert check is recorded in the PR body.
- [ ] `aiur_agent_skill_test.exs` still passes (the creation-rule blocks are
      unchanged, so `agent:todo` stays the first rule an agent reads).
- [ ] The docs build passes.
- [ ] Manual follow-through transcript in the PR.
- **Hands off to:** C12-T07 (links to the `skills.md` paragraph; does not copy
  it) and C13-T04 (the backfill runbook follows the same rules through the
  tools with `backfill: true` / `"source": "backfill-agent"`, because it runs
  in a workspace).
- **Sources:** E8-D7, E8-D9 (decisions.md); README rows and ticket files
  C5-T03 (§3.4, §4.5, §4.6, §10, §11), C6-T03, C6-T04 (command surface,
  decisions 1 and 6), C7-T03 (§4.6, decision 4), C12-T07; plan §10 items 10, 14; AGENTS.md "Docs ship with the change"
  and "Tests must fail without the production change they guard".

## Interface requests

The neighbour ticket files already give most of what this ticket needs:
engine-side argument checks (C5-T03 §4.5, C6-T04 step 1, C7-T03 §4.6), a
required non-empty `--reason` (C7-T03 §4.6), and `default_hours/1` (C7-T03
§4.1). Only these remain:

1. Settled 2026-10-08: C5-T03's `aiur_set_epic` unknown-epic error lists the
   valid keys, as the CLI refusal does; the worker block reads that error.
2. **C5-T03, C6-T04, C7-T03: keep the shape checks in the engine functions**
   `cmd_epic`, `cmd_feature`, `cmd_ticket`, callable with a stubbed
   `run_control_rpc`, as their own engine tests already do. T2 relies on that;
   if a predecessor moves its checks into Elixir, T2 calls that function
   instead.

## Decisions made without the owner

1. **No edit to the per-turn prompt.** The row names "planner prompts
   (`src/prompts/`)". At `58854d4c8` that directory holds only
   `shared-agent-instructions.md`, the per-turn issue-worker prompt; there is no
   planner prompt. Planning agents read `aiur-build` and `aiur-run`. Adding the
   rule to the shared prompt would cost tokens on every turn for a rare action
   and break its own scope rule. If a planner prompt is added later, it should
   point at the aiur-build paragraph.
2. **`aiur-meta` is included** although the row lists aiur-build, aiur-run and
   aiur-agent. It files tickets and is already in `@creation_rule_docs`; leaving
   it out would make meta findings the one Unsorted stream.
3. **Issue workers get the epic rule but not the estimate rule.** E8-D7 gives
   overrides to the Executor's planning agent.
4. **Unsure means unset.** "Strongly encourage a category" (E8-D9) is not
   permission to guess. Unsorted is the true state; a wrong column misleads the
   operator.
5. **Epics are set by command, not by type labels.** Label matchers are per
   repository (C5-T01), so a skill cannot know which label means `bugs`. The
   command is the same on every repository.
6. **Build Order members use their `build-lane:` label.** No `aiur epic set`
   call is taught for them, because C6-T03 maps each sub-issue's lane to a
   feature epic.
7. **T2 copies `run_sourced_engine/2`** (a third private copy, with its
   node-isolation guard) instead of moving it to `test/support/`. Moving it
   touches two existing test files for no behaviour change; the copy is about
   20 lines. If a fourth caller appears, extract it then.
8. **Issue workers are taught the tools, not the CLI.** The README row says
   "run the batch CLI", but C5-T03 §3.4 shows the CLI cannot reach the daemon
   from a workspace and the engine refuses `--source agent:`. The Executor docs
   teach the CLI; the worker doc teaches `aiur_set_epic` / `aiur_feature`.
9. **Executors read keys with `aiur epic list`.** C5-T03 ships `aiur epic
   list [--json]`; agents, which cannot run the CLI, read the valid keys from
   `aiur_set_epic`'s unknown-epic refusal.
10. **Lane choice points at the existing rule** in
    `decomposition-workflow.md:202-207` (3–6 lanes) instead of a new one. The
    design mock's two epics per feature (J:105-111) is sample data, not a rule.

## Review log

Adversarial review, 2026-10-08, against the runtime at `58854d4c8` and the
neighbour ticket files C5-T03, C6-T03, C6-T04, C7-T03, C12-T07.

1. Issue-worker path was wrong: it taught `aiur epic set --source agent:<id>`,
   which C5-T03 refuses (V-26) and which cannot reach the daemon from a
   workspace (§3.4). Split Rule A into an Executor form (CLI) and an
   issue-worker form (`aiur_set_epic`, `aiur_feature` tools); updated T1, T5,
   T7, the skills.md paragraph and the non-happy paths.
2. Removed `aiur epic list` (no such verb in C5-T03). The guidance now uses the
   unknown-key refusal, which lists valid keys; T4 asserts that sentence.
3. Replaced the requested "pure argv parser" with the real engine checks
   (`cmd_epic`, `cmd_feature`, `cmd_ticket`) through the existing
   `run_sourced_engine` harness (`aiur_engine_test.exs:1388-1401`, `:1737`), and
   added tool-name and argument checks against `DynamicTool.tool_specs/0`
   (`dynamic_tool.ex:35-38`). T2 now also refuses an empty extraction.
4. Interface requests rewritten: dropped the four already met by neighbours
   (parser, `--reason` required, `default_hours/1`, epic list); kept the tool
   error listing keys and the engine-check location.
5. Added the marker hazard: a new paragraph with "same creation request" would
   be picked up by the existing creation-rule test and fail on `build-lane:`.
6. Rule A′: added that members need the `build-lane:<lane>` label and the
   sub-issue link (what C6-T03 reads); pointed lane choice at the existing
   `decomposition-workflow.md:202-207` rule instead of a conflicting new one.
7. Rule B: added the one-line, 500-character reason limit and the `--clear`
   form (C7-T03 §4.6); T6 reads hours from `Estimates.default_hours/1`.
8. Added the `aiur feature add` cross-feature refusal and `--move` to the
   executor.md variation and a non-happy path.
9. Line fixes: `metadata.ex:109-119` (regex at `:119`), `skills.md:45-59`
   (Executor table) and insertion after `:43`, `aiur-agent/SKILL.md:77-87`,
   `aiur-build/SKILL.md:231-236`; replaced a non-existent AGENTS.md quote
   ("unknown is never zero") with the real section name.
10. Manual check rewritten for the Executor CLI path (the worker cannot run the
    CLI) plus a shipped-skill check in a fresh workspace; successor note for
    C13-T04 now uses the tools.
11. Verification command now isolates HOME and unsets GitHub tokens (same form as C6-T04).
- Reconciliation 2026-10-08 (coordinator): manual check expects source `cli:$USER` (C5-T03 CLI source string `cli:<who>`), interface request 1 (unknown-epic error lists valid keys) marked settled; no S-item numbers cited, so R-G13 needed no change.
- Reconciliation 2026-10-08 (coordinator, second pass): decision 9 uses C5-T03's `aiur epic list`.

# Reduce hot-file merge conflicts (#4282)

## Contract and rollout

Preserve commands, config keys, field values, list order where meaningful, and
all gate strength. Land the list layout alone first; land the docs split second
at an Executor-selected quiet point. No saving is claimed before measurement.

## Decisions

- Store the 49 components in `components/<id>.json`, with an explicit file
  index in `components.json`. Expanded monolithic JSON needs 2,213 lines;
  the largest expanded component needs 105. Load and validate the assembled
  manifest through the existing schema and reference/ownership gates.
- Use deterministic JSON indentation and sorted string sets, including paths,
  facades, dependencies, and owns entries. Preserve component-object order
  where meaningful; do not sort supervisor child order or lifecycle events.
- Existing TSV exemptions already have one entry per line. Sort complete rows;
  keep every reason and the exemption population identical.
- Do not ship union merging for JSON or sorted/unique lists. Demonstrate
  ordinary GitHub merges and probe union on scratch-only plain text. Record
  same-position insertion conflicts instead of implying layout eliminates them.
- Preserve legacy docs anchors through an index linking each moved topic.
  Split CLI into launch, operations, decisions, and development; split config
  into daemon, tracker/polling, agents, integrations, and build orders.
  Every topic stays below 400 lines and appears in the sidebar.

## Units

### U1 — mechanical list layout and enforcement

Files: `components.json`, `components/*.json`, `scripts/check-components.py`,
`scripts/components/manifest.py`, allowlist TSVs, lifecycle attributes, pinned
child attributes, workflow security, contributor guidance, formatter tests.
Keep inline manifest fixtures supported. Checkers and their direct-reader tests
must load the same assembled manifest. A carry-over helper replays added list
members by component ID/key and refuses scalar changes or removals.

Tests: formatter rejects a single-line list; sorts unordered sets; preserves
ordered code lists; rejects duplicate/missing/unsafe shard references; keeps
all manifest values and exemptions; remains idempotent. New tests must fail
with their production hunks reverted in an isolated worktree.

### U2 — topic docs and reader migration (after U1 landing)

Files: reference CLI/config indexes and topic pages, sidebar, config checker,
CLI checker if present, docs-reading Elixir and browser tests.

Tests: every original command/flag/config row survives exactly once; every
original section has a reachable destination; missing topic/row fails gates;
all split pages stay below 400 lines; docs build and affected browser specs.

### U3 — evidence and Executor handoff

Count all open PRs touching each hot file at publication using PR file lists.
Record one week of merged-PR conflict evidence with dates and limitations;
do not treat approval counts as conflict counts. Demonstrate two real GitHub
branches adding distinct members to one manifest list and one docs table.
Record both mergeability and both values surviving the GitHub comparison.
Provide one-command migration and a section-to-page map for rollout.

## Risks and verification

The first landing overlaps open PRs; migration must preserve both sides.
Adjacent additions still conflict. Union can introduce duplicates and violate
sorted/unique content. Scratch PRs must remain drafts and be closed after
read-only mergeability evidence; the agent cannot approve or merge them.

Run focused Python/shell formatter/component fixtures, affected Elixir tests
with `--max-cases 4`, compile, format, lint, bare-receive and structural gates.
Full required CI on the pushed head remains the review handoff gate. Manual
`aiurdev --test` is prohibited from this agent workspace.

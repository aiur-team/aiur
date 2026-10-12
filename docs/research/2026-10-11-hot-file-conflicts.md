# Hot-file rollout evidence (#4282)

## Separate landings

Land the list layout alone first. Then land the topic docs split at a quiet
point selected by the Executor. The parent ticket is incomplete until both
stages and their acceptance gates are delivered. No measured saving is claimed.

## Layout choice and preservation

The initial snapshot had 49 components. Expanded monolithic JSON would occupy 2,213 lines;
the largest expanded component occupies 105. `components/<id>.json` holds each
component, indexed explicitly by `components.json`. Readers assemble the same
manifest and validate the existing schema, ownership rules, and reference gates.

A comparison against the pre-change manifest confirmed all 49 components,
22 seams, and 3 ports identical after normalizing unordered string sets and
component order. Every TSV exemption and its reason survived unchanged.
Ordered event, field, and supervisor lists retain their original sequence.

After integrating main at `eac895dd87675ac89f201be2cd294884f08c4b62`, the
assembled manifest matches all 50 components, 23 seams, and 3 ports from main.
The new experiments component and changed control/workspace ownership survive.
A pushed rescue ref preserves the pre-integration feature head `5bf92eb86aa6a379e78ca6e39bd9f565acd66784`.

## Open-PR population

Observed 2026-10-11 17:26:58 UTC, before creating the scratch demonstrations:
89 open PRs. Command: `gh pr list --state open --limit 100 --json number,headRefName,baseRefName,files`.
The PR census fits one page. PR #2418 has more than 3,000 changed files;
its complete 5,066-file Git comparison was checked separately and touches
none of these hot files. Counts below name exact hot-file overlaps.

| Hot file | Open PRs | PR numbers |
| --- | ---: | --- |
| `components.json` | 23 | 4283, 4279, 4250, 4247, 4233, 4230, 4215, 4195, 4173, 4165, 4154, 4060, 4039, 4038, 4023, 4021, 4000, 3989, 3930, 3916, 3894, 3855, 3557 |
| `website/docs-app/reference/cli.md` | 11 | 4279, 4257, 4250, 4247, 4165, 4152, 4014, 3894, 3830, 3006, 2643 |
| `website/docs-app/reference/configuration.md` | 9 | 4257, 4152, 4064, 3928, 3894, 3006, 2946, 2870, 2510 |
| `src/lib/aiur/run_telemetry/lifecycle.ex` | 5 | 4283, 4255, 4195, 4000, 2936 |
| `src/test/support/state_writers_allowlist.exs` | 2 | 4218, 4154 |

The component exemption files have the following overlaps.

| TSV allowlist | Open PRs | PR numbers |
| --- | ---: | --- |
| `accounting.tsv` | 1 | 3989 |
| `agent-runner.tsv` | 2 | 4000, 3989 |
| `agent-sandbox.tsv` | 2 | 3989, 3855 |
| `commands.tsv` | 1 | 3989 |
| `config.tsv` | 1 | 3989 |
| `control-cli.tsv` | 2 | 4021, 4014 |
| `dashboard-ui.tsv` | 1 | 3989 |
| `event-bus.tsv` | 1 | 3989 |
| `executor-attention.tsv` | 1 | 4021 |
| `github.tsv` | 1 | 3989 |
| `harness-adapters.tsv` | 3 | 4000, 3989, 3855 |
| `identity.tsv` | 1 | 3989 |
| `orchestration.tsv` | 3 | 4195, 3993, 3855 |
| `telemetry.tsv` | 2 | 4283, 3989 |
| `tui.tsv` | 1 | 4000 |
| `web-shell.tsv` | 1 | 3989 |
| `workspace.tsv` | 2 | 4000, 3989 |

All other component exemption TSVs have zero overlap in this census.

The Executor should refresh this census immediately before landing. It is an
observation, not a stable population estimate. A PR's file list must be complete
before counting it; the final handoff records any API pagination limitations.

## Refreshed publication population

Observed 2026-10-11 18:16:31 UTC: 89 open PRs, including this draft (#4295).
The same census command was used; the only truncated file list remains #2418,
whose complete Git comparison above has no hot-file overlap.

| Hot file | Open PRs | PR numbers |
| --- | ---: | --- |
| `components.json` | 23 | 4295, 4283, 4279, 4250, 4247, 4233, 4230, 4215, 4195, 4173, 4165, 4154, 4060, 4039, 4038, 4023, 4021, 4000, 3989, 3930, 3916, 3855, 3557 |
| `website/docs-app/reference/cli.md` | 10 | 4279, 4257, 4250, 4247, 4165, 4152, 4014, 3830, 3006, 2643 |
| `website/docs-app/reference/configuration.md` | 9 | 4287, 4257, 4152, 4064, 3928, 3006, 2946, 2870, 2510 |
| `src/lib/aiur/run_telemetry/lifecycle.ex` | 6 | 4295, 4283, 4255, 4195, 4000, 2936 |
| `src/test/support/state_writers_allowlist.exs` | 3 | 4295, 4218, 4154 |
| `scripts/components/allowlist/accounting.tsv` | 1 | 3989 |
| `scripts/components/allowlist/agent-runner.tsv` | 3 | 4295, 4000, 3989 |
| `scripts/components/allowlist/agent-sandbox.tsv` | 2 | 3989, 3855 |
| `scripts/components/allowlist/commands.tsv` | 1 | 3989 |
| `scripts/components/allowlist/config.tsv` | 2 | 4295, 3989 |
| `scripts/components/allowlist/control-cli.tsv` | 2 | 4021, 4014 |
| `scripts/components/allowlist/dashboard-ui.tsv` | 2 | 4295, 3989 |
| `scripts/components/allowlist/event-bus.tsv` | 1 | 3989 |
| `scripts/components/allowlist/executor-attention.tsv` | 1 | 4021 |
| `scripts/components/allowlist/github.tsv` | 2 | 4295, 3989 |
| `scripts/components/allowlist/harness-adapters.tsv` | 3 | 4000, 3989, 3855 |
| `scripts/components/allowlist/identity.tsv` | 1 | 3989 |
| `scripts/components/allowlist/orchestration.tsv` | 3 | 4195, 3993, 3855 |
| `scripts/components/allowlist/telemetry.tsv` | 2 | 4283, 3989 |
| `scripts/components/allowlist/tui.tsv` | 1 | 4000 |
| `scripts/components/allowlist/web-shell.tsv` | 1 | 3989 |
| `scripts/components/allowlist/workspace.tsv` | 3 | 4295, 4000, 3989 |

## Real GitHub branch demonstration

Scratch PRs [#4289](https://github.com/aiur-team/aiur/pull/4289) and
[#4290](https://github.com/aiur-team/aiur/pull/4290) each added one member to
`components/kernel.json`'s `paths` list and one row to the existing tracker
configuration table. The additions use opposite ends of each list/table.

The branches share base `1b58c30b79df5bf0eaafc80b9d5a3c2920f36e14`.
Alpha is `6ec3b84b9e3db687ebe4597f30e1af7fc87f30dc`; omega is
`c4a0493dd7aceddf4be4e54ff200361a14a761ca`. PR #4290 targets alpha.
GitHub reported `MERGEABLE` for both PRs.

The generated GitHub merge `3aa9bd89ecf36cdbef04b96e29f1177b406c71c5`
contains both paths and both rows exactly once. It was read, never landed.

```bash
gh pr view 4290 --json mergeable,headRefOid,baseRefName
git -C "$workspace" fetch origin pull/4290/merge:refs/aiur/4282-proof-native-merge
git -C "$workspace" show refs/aiur/4282-proof-native-merge:components/kernel.json
git -C "$workspace" show refs/aiur/4282-proof-native-merge:website/docs-app/reference/configuration.md
```

Assertions on the fetched JSON required one occurrence each of
`src/lib/aiur/a_merge_proof_alpha.ex` and
`src/lib/aiur/zz_merge_proof_omega.ex`. Assertions on the fetched table required
one occurrence each of `tracker.merge_proof_alpha` and `tracker.merge_proof_omega`.

This proves independent insertion sites merge with both sides intact. It does
not prove adjacent insertions or concurrent edits of the same row merge.
Splitting components removes cross-component contention; same-component
same-position additions can still need manual reconciliation.

## Union experiment: local success, GitHub conflict

Scratch PRs [#4291](https://github.com/aiur-team/aiur/pull/4291) and
[#4292](https://github.com/aiur-team/aiur/pull/4292) tested `merge=union` only
on an unordered plain-text fixture. Both inserted at the same position.
The scratch `.gitattributes` declared `docs/merge-proof-4282.txt merge=union`.

```bash
git -C "$scratch_worktree" switch --detach refs/heads/aiur/4282-proof-union-left
git -C "$scratch_worktree" check-attr merge -- docs/merge-proof-4282.txt
git -C "$scratch_worktree" merge --no-commit --no-ff refs/heads/aiur/4282-proof-union-right
git -C "$scratch_worktree" merge --abort
gh pr view 4292 --json mergeable,headRefOid,baseRefName
```

The real local merge reported success and produced `alpha`, `left`, `right`,
`omega`, one line each. GitHub reported `CONFLICTING`; fetching
`pull/4292/merge` failed because that merge ref did not exist. Thus the local
union behavior is not portable to GitHub in this tested scenario.

No union attribute ships. JSON commas make union unsafe; sorted/unique
exemption lists can become unsorted or duplicated. All four scratch PRs were
closed after verifying their bodies, branch identities, and results.

## One-week baseline: recorded lower bound

The complete paginated merged-PR census for the seven days ending
2026-10-11 17:26:58 UTC contains 437 PRs. Query:

```bash
gh api --method GET search/issues --paginate \
  -f q='repo:aiur-team/aiur is:pr is:merged merged:2026-10-04T17:26:58Z..2026-10-11T17:26:58Z' \
  -f per_page=100 --jq '.items[] | {number,closed_at}'
```

Only the Oct 8–11 Executor decision log is available locally. Its explicit
hot-file conflict records identify at least seven conflict episodes in six
PRs that appear in the week's merged census. Repeated observations of the
same unresolved conflict are counted once; approval counts are not counted.

| File | Recorded episodes | Merged PRs and source log entries |
| --- | ---: | --- |
| `components.json` | 7 | #3910 (line 469), #3942 (508), #4217 and #4078 (796), #4212 (805 and 841), #3984 (830) |
| CLI/config refs, lifecycle metadata, allowlists | unknown | No qualifying explicit merged-PR episode in the available log; this does not mean zero conflicts. |

Source: `executor/decision-log-20261008.md`, entries from Oct 10–11.
Entries 797 and 835 repeat the same unresolved cases and are not added.
Open PRs #3894 and #3849 are excluded from the merged-PR baseline even though
they repeatedly conflict. The original ticket documents those ongoing cases.

**The full week's conflict total is unknown.** Oct 4–7 evidence is unavailable,
and squash commits on main discard branch merge histories. A factual request
asks the Executor for those missing records. Seven is a reproducible lower
bound, not the requested complete before/after metric.

## Carry an existing PR's additions

From a clean checkout containing the new layout:

```bash
python3 scripts/carry-component-additions.py --pr 3894
```

The helper fetches the actual PR head, validates both historical manifests,
and replays added members by component ID and nested key without dropping
current-side additions. It refuses removals, scalar edits, and conflicting new
components for manual reconciliation. Review the resulting diff and run the
component gates before committing; it neither commits nor pushes.

The docs-stage handoff will supply the exact moved-section map and a carry-over
command for docs changes. Those are pending work, not delivered by this stage.

# Harness-adapters promotion record

MP-R7-C4-T02 / [#3477](https://github.com/aiur-team/aiur/issues/3477).
Measured **2026-10-21 UTC** against
`83ff082d5dc0b2aace44ff64520c0ca49b6135f7` on `main`.

**NO-GO for physical packaging (C4-T03..T05).** Criteria 1, 3 and 5 do
not pass. Keep the logical component in `src/`; this decision completes
the evidence ticket without authorizing a package move. Re-check when a
second consumer or independent-release need is recorded, or MP-R1-C11
requests a refresh. All five criteria must pass at that re-check.

The original research plan and chunks are absent from this checkout.
This is a new, bounded evidence section at the ticket's requested location,
not a restoration of the historical plan. The current component record is
[`components/harness-adapters.json`](../../../../../components/harness-adapters.json).
The [C4 disposition](chunks.md) uses the revised ticket IDs from #3477.

## Governing evidence

- [MP-R1 migration-plan §5 at research revision 6732f5f9](https://github.com/aiur-team/aiur/blob/6732f5f9f448b1857a9643993849635f85321e19/docs/research/aiur-mobile-and-platform/bucket-1-refactor/MP-R1/migration-plan.md#5-promotion-test-when-a-logical-component-becomes-a-physical-package): all five criteria are required.
- [DESIGN-R7 approval at 9ce9fdc](https://github.com/aiur-team/aiur/blob/9ce9fdc67bd3031ba9e61cec0bf69c19401232f1/docs/research/aiur-mobile-and-platform/owner-design-tasks/EXECUTOR-APPROVALS.md#design-r7-mp-r7-harness-adapter-extraction): behavior stays unchanged; foreground smoke is sufficient manual proof, not a waiver of the promotion criteria.
- Boundary rule [#5440](https://github.com/aiur-team/aiur/pull/5440) merged
  at `657a25098cbc182c8ce62a29b3905bd9452461f7`, 2026-10-20 23:17:13 UTC.
- Supervision [#5200](https://github.com/aiur-team/aiur/pull/5200) merged
  at `f7e9be34e944288e62fcd9bae8f90ac4fae4cd66`, 2026-10-19.
- Config ownership [#3531](https://github.com/aiur-team/aiur/pull/3531) merged
  at `dd7fc3f5769500c39f17531663ed8e9089d09d6f`, 2026-10-08.

## Five-criterion scorecard

All measurements below have the date and source head stated above.
Release coverage is `v0.0.7` and `v0.0.8` for criterion 1; other rows
describe the source head, not released behavior.

| Criterion | Measured value | Result | Reproduce |
| --- | --- | --- | --- |
| 1. Zero allowlisted violations in/out for two consecutive releases | 0 qualifying releases; current head has 94 live allowlisted keys: 54 outgoing, 40 incoming | FAIL | A, B |
| 2. Component declares children and boot ordering; root composes | 1 declared child: `Aiur.Claude.Telemetry`; provider `init_order: 0`; root calls the facade | PASS for current logical shape | C; #5200 |
| 3. State/recovery moves together; tests run without whole app | Prescribed `--no-start` selection fails: 1,345 tests + 2 properties, 34 failures, 1 excluded (seed 65068) | FAIL; state portability is not established by this run | D |
| 4. Config section owned in manifest | Exactly 1 owner of `agent`: `harness-adapters` | PASS | B; #3531 |
| 5. Second consumer exists/planned, or independent release is needed | 0 named second consumers or independent-release requirements in the cited promotion/design records | NOT ESTABLISHED; no-go | E |

### A. Releases and checker availability

```sh
workspace="$AIUR_AGENT_WORKSPACE"
gh release list --limit 4
gh pr view 5440 --json mergeCommit,mergedAt
git -C "$workspace" rev-parse 'v0.0.8^{commit}' 'v0.0.7^{commit}'
for tag in v0.0.8 v0.0.7; do
  git -C "$workspace" cat-file -e "$tag:scripts/check-components.py"
  git -C "$workspace" cat-file -e "$tag:components.json"
done
```

The latest stable tags are `v0.0.8` (2026-09-30,
`ed43c0e94`) and `v0.0.7` (2026-09-30, `465aca643`). Both precede
the boundary rule merge. Both `cat-file` probes fail on both tags:
neither contains the checker or manifest. Their violation count is
**unavailable**, not zero. There are no two post-rule releases to score.
The rolling `streamdeck-nightly` pre-release is not an Aiur release.

The checker has neither `--component` nor `--report` (confirmed with
`python3 scripts/check-components.py --help`). Use its full report plus
the ownership-based subset below. No new checker contract is needed to
make this decision; the fallback can count both directions accurately.

### B. Current boundary and ownership census

From the repository root:

```sh
npm ci --prefix scripts/components --ignore-scripts
mise exec -- python3 scripts/check-components.py --require-elixir
mise exec -- python3 - <<'PY'
import importlib.util, pathlib, subprocess, sys
sys.path.insert(0, 'scripts')
spec = importlib.util.spec_from_file_location('checker', 'scripts/check-components.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
root = pathlib.Path.cwd()
manifest = c.load_manifest(root)
_, _, owners = c.ownership(manifest, c.source_files(root))
violations, _ = c.module_violations(root, manifest, owners)
walk = subprocess.check_output([
    'elixir', 'scripts/components/module_references.exs', str(root), '--files',
    *[p for p in owners if p.endswith('.ex')]], text=True)
modules = {a[2]: owners[a[1]] for row in walk.splitlines()
           if (a := row.split('\t'))[0] == 'M' and a[1] in owners}
keys = [k for k in c.read_allowlist(root, manifest)
        if k[1] == 'harness-adapters' or modules.get(k[2]) == 'harness-adapters']
print('total/outgoing/incoming/live:', len(keys),
      sum(k[1] == 'harness-adapters' for k in keys),
      sum(k[1] != 'harness-adapters' for k in keys),
      sum(k in violations for k in keys))
print('agent owners:', [x['id'] for x in manifest['components']
                        if 'agent' in x['owns']['config']])
PY
```

Full checker: exit 0, 2,130 Elixir modules and 81,135 references.
Subset: `94 54 40 94`; owner: `['harness-adapters']`.
Keys are distinct `(rule, source component, target module)` exemptions,
not reference occurrences. A passing ratchet permits existing debt;
it does not satisfy the promotion requirement of zero debt.

### C. Supervision declaration

```sh
env -C src mise exec -- mix run --no-start -e 'children = Aiur.CodingAgent.child_specs(); IO.inspect(Enum.map(children, &Supervisor.child_spec(&1, []).id), label: "harness children"); IO.inspect(length(children), label: "count")'
rg -n 'children:|init_order:' src/lib/aiur/coding_agent/providers/claude.ex
rg -n 'CodingAgent.child_specs' src/lib/aiur/application/children.ex
rg -n 'strategy' src/lib/aiur.ex
```

Output: `[Aiur.Claude.Telemetry]`, count `1`. ProvidersView orders provider
entries by `init_order` and deduplicates child IDs. The composition root
uses `:rest_for_one`; the provider supplies its child module's OTP spec.
This is source-level declaration evidence, not a release boot smoke.

### D. Test independence probe

```sh
env -C src mise exec -- mix test --no-start --max-cases 4 test/aiur/codex test/aiur/claude test/aiur/muse test/aiur/open_ai_compat test/aiur/coding_agent test/aiur/app_server test/aiur/agent_tools test/aiur/coding_agent_test.exs
```

Exit 2, seed `65068`: 34 failures in 46.0 seconds. A second capture run
was used to inspect failure causes after the first output was truncated;
it does not turn the failed criterion into a pass. Seed `215692` produced 31
failures in 90.8 seconds: 18 missing `Aiur.PubSub` failures in hook-turn
tests, 10 unstarted-timezone-support failures
(`:utc_only_time_zone_database`), and 3 Muse fixtures missing expected
`usage/read` frames. The latter are not classified as missing process
failures. Counts vary with seed; both runs fail. This probe is promotion
evidence, not normal CI.

The exact prescribed roots are used, including the sibling
`coding_agent_test.exs`; this is not a claim that every file currently
owned by the expanded component has independent test coverage. No code,
tests, durable state, recovery, or migration files are moved by this record.

### E. Consumer/release need and manual acceptance

Read migration-plan §5 and DESIGN-R7 at the revisions linked above with
`git -C "$workspace" show <revision>:<path>`.
The former names Khala for listener-modes and mobile for aiur-contracts;
it names the adapters as late candidates, without a second consumer.
DESIGN-R7 approves extraction with unchanged packaging, not independent
adapter releases. Current manifest `kind` is `in-app`, install type
`included`. This is a bounded evidence search, not proof that no future
consumer can exist. An owner-stated release need would warrant re-checking.

The approved foreground check was **not run in this issue workspace**.
After deployment, the Executor must run `scripts/aiurdev --test --force
--allow-remote` from the Executor repository root, following
[`docs/manual-testing.md`](../../../../../docs/manual-testing.md).
Run one Codex and one Claude agent; open each chat pane with Enter,
type a distinct message through its input, and observe delivery and
rendered agent responses using the launched socket/session. Stop that
instance after capture. A successful smoke alone cannot change this no-go.

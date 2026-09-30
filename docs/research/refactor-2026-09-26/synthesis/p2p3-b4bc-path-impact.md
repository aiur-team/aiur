# P2/P3 cited-path exposure at `main@b4bc11f`

The [path-impact CSV](p2p3-b4bc-path-impact.csv) is a reproducible intersection
of all 889 canonical P2/P3 findings' raw cited paths with the public Git diff
from frozen source `3339b887196d5e9aefb273117a14bf33391ee41f` to detached
`b4bc11ffcb6abf693bb3c8570aca3e12d82cb24f`. The
[`p2p3_path_impact.py` script](../tooling/p2p3_path_impact.py) loads the
effective action after both reconciliation overlays. Run:

```sh
python3 docs/research/refactor-2026-09-26/tooling/p2p3_path_impact.py \
  --base 3339b887196d5e9aefb273117a14bf33391ee41f \
  --head b4bc11ffcb6abf693bb3c8570aca3e12d82cb24f \
  --output docs/research/refactor-2026-09-26/synthesis/p2p3-b4bc-path-impact.csv
```

Two independent read-only recounts agreed with every generated ID, path,
status and action. Of 318 changed paths, 356 P2/P3 findings cite at least one:
79 provisional fixes and 277 deferrals. Twenty-seven findings cite at least
one deleted path (38 deleted-path occurrences). The deleted citations chiefly
touch the removed GitHub cache surface, budget map and local deletion guard;
they are not automatic finding closures.

This is **file-level exposure, not behavior impact**. A modified file may not
change the cited branch; a deleted file may have a replacement that preserves
the behavior; an unchanged citation may be affected by a changed caller,
configuration or new module. Six of the nine specially reconciled IDs cite no
changed path. `github-b-14` intersects a changed `read_cache.ex` citation
while its focused test-token seam is in unchanged `transport.ex`;
`skills-prompts-cont-20` intersects a workflow change while the erroneous
release recipe remains. Use the CSV to schedule a full flow re-trace alongside
the 533 unchanged-path findings, not as a severity or incidence ranking.

Before a P2/P3 finding becomes worker-ready, compare the cited hunk and all
callers on final release main, find any replacement path, reproduce the failure
or name the missing evidence, and provide a behavior test that fails on the
original behavior. The current plan's 244 fixes and 645 deferrals remain
provisional.

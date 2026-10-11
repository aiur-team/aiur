# Optimistic-start arm setup

This is the Executor procedure for experiment `optimistic-start` (#3812),
measuring #3755. Run it before treatment data exists. The concurrent A/B
comparison supplies the verdict; the line at #3755's close supplies context
about the default `pr_merged` path.

## Prepare the assignment

1. Take the next Build Order's planned dependency graph and record its revision.
   Preserve issue numbers, prerequisite edges, complexity and gate identities.
2. Remove review-gate tickets from the experimental population. This removes
   them from the assignment graph, **not** from GitHub's prerequisites or the
   Executor's review process. Keep their sign-off outside treatment queues.
   Record removed gates and their incident edges; never delete live blockers
   to make an experimental arm runnable.
3. Treat each remaining prerequisite edge as undirected and list the weakly
   connected components, including isolated tickets. Sort each component by
   issue number, then sort components by their smallest issue number.
   Account for prerequisites outside the Build Order before assignment: a
   shared external blocker must not silently connect the two arms.
4. Choose and record a seed before inspecting outcomes. In the sorted order,
   draw one fair seeded coin per component: 0 = control, 1 = treatment.
   Record the random generator and version with the seed and every assignment.
   Assign whole components; never split a dependency chain across queues.
   Keep a one-arm or single-component result as an insufficient assignment;
   do not reroll to obtain a favorable split. Accumulate further Build Orders.
5. Dry-run by listing the removed gates, components, assignments and the two
   commands below with their actual issue numbers. Printing commands does not
   create queues. Record the graph revision, seed, component lists, queue names
   and dry-run output with the experiment before executing either command.

```bash
aiur queue add <control issue numbers> --queue optimistic-start-control --start-on pr_merged
aiur queue add <treatment issue numbers> --queue optimistic-start-treatment --start-on pr_opened
```

Use explicit ticket lists rather than `--build-order`: adopting the entire
root would include gates and tickets assigned to the other arm. Execute queue
mutations from the Executor checkout; agent workspaces cannot change queues.
Confirm membership and triggers with `aiur queue show --json`. Cohort selectors
must use the resulting recorded `queue_id` values, not assumed display names.
If either arm is empty, print that fact and omit its invalid empty command.

## Before starting treatment

- Confirm #3763, #3765, #3766 and the #3772 merge-order gate are merged.
- Register the reviewed spec through the X2 store. Import the frozen
  `baseline-2026-10-09/baseline.json` with its SHA-256; do not regenerate it.
  Confirm the stored baseline reports gap n=27 and median 0.78 hours.
- Exclude late-linked dependents. Require 20 eligible chain-gated dependents
  per arm (target 40) and 10 per arm within each reported complexity stratum.
  Report hub-gated and chain-gated dependents separately.
- Use Mann-Whitney U and a graph-component cluster bootstrap, with Holm
  correction across chain lead time and the two primary metrics.
- Stop recommendations: discard rate >20% after at least 10 optimistic starts;
  dependent rework >46.5%; any merge-order violation; main-red >53.5% over
  24 hours. The latter two percentage thresholds use the frozen baselines
  26.5% + 20 points and 38.5% + 15 points. The Executor acts on recommendations.
- Record restarts, cap changes, backend/model mix, provider pauses, main-red,
  dispatch/queue/CI changes and G5 landings as confounders. Keep redo rate and
  wasted agent hours in reports without inventing additional stop rules.

While #3755 is open, its context line remains pending. Once closed, resolve
the line to the latest sub-issue PR merge timestamp, preserving its evidence.

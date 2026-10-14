# Arm assignment dry run, 2026-10-14

This read-only check uses the current #3774 sub-issue graph, not a new
enrollment population. Some tickets have already started. Do not execute the
printed queue command against this population.

Source: GitHub REST `issues/3774/sub_issues` and each sub-issue's native
`dependencies/blocked_by`, captured at 2026-10-14T15:44:24Z. All responses fit
one 100-item page; 32 sub-issues were returned. No review-gate tickets or
external prerequisite anchors were identified in this graph.

The [captured graph and assignments](arm-dry-run-2026-10-14.json) preserve
closed prerequisite nodes so shared blockers do not silently split a
component. Sort issue numbers within each component and sort components by
their smallest issue number. Python `random.Random(3812).getrandbits(1)`
draws 0 for control or 1 for treatment once per component in that order.

Components:

- Component 1: 3779–3795, 3797–3804, 3806–3809, 3812 (30 tickets).
- Component 2: 3796 (one ticket).
- Component 3: 3811 (one closed ticket).

All three coins selected treatment. The 22 open tickets produce this command
for inspection only:

```bash
aiur queue add 3780 3781 3782 3783 3784 3785 3786 3787 3788 3789 3790 3791 3792 3796 3798 3799 3800 3801 3802 3803 3804 3812 --queue optimistic-start-treatment --start-on pr_opened
```

Control is empty, so there is no valid control queue command. Its eventual
form is `aiur queue add <control issue numbers> --queue optimistic-start-control
--start-on pr_merged`, as documented in [arm setup](arm-setup.md).

Result: **insufficient assignment; no enrollment**. Do not reroll or split the
large component to force two arms. This graph demonstrates why the procedure
must allow accumulation across Build Orders. Only a future, unstarted,
pre-registered population can supply the actual experiment queues.

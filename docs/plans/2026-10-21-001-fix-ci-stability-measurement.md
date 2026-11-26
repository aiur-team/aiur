# CI stability plan: measuring each remedy

Companion to `2026-10-21-001-fix-ci-stability-feature-throughput-plan.md` (split out to keep each file under 500 lines).


The Executor creates each experiment when its remedy merges, with `aiur experiments create --from spec.json`. Replace `<merge-sha>` and `<merge-time>` with the merge commit and its UTC merge time. Creation freezes the 14-day baseline. Metrics marked *new* come from U1. Cohort filters use `feature_tags` and `tags.work_kind` (U1); see Q5.

Common fields for every spec: `"schema_version": 1`, `"owner": {"kind": "agent", "id": "executor"}`, `"origin": {"kind": "manual", "ref": null}`, `"status": "active"`, `"alpha": 0.05`, `"power_target": 0.8`, `"design": {"kind": "before_after", "assign_by": "start", "change": {...}}`.

**E1 (U1, baseline only).** No change line is needed. After U1 merges, run `aiur experiments create --draft` once per new metric to confirm coverage over the previous 14 days.

**E2 (U2, affected selection).**

```json
{
  "schema_version": 1,
  "key": "ci-stability-u2-affected-selection",
  "title": "Restore affected-test selection on PRs",
  "hypothesis": "PR CI runs affected tests again, so PR CI wall time, CI wait and PR failure rate fall, and more merges are feature work.",
  "owner": {"kind": "agent", "id": "executor"},
  "origin": {"kind": "manual", "ref": null},
  "status": "active",
  "design": {"kind": "before_after", "assign_by": "start", "change": {"type": "merge", "ref": "<merge-sha>", "time": "<merge-time>"}},
  "metrics": [
    {"ref": "delivery-speed/pr_ci_wall_time", "direction": "decrease", "primary": true},
    {"ref": "delivery-speed/ci_wait", "direction": "decrease", "primary": false},
    {"ref": "delivery-speed/ci_run_failure_rate", "direction": "decrease", "primary": false},
    {"ref": "delivery-speed/pr_open_to_merge", "direction": "decrease", "primary": false},
    {"ref": "delivery-speed/merge_group_failure_rate", "direction": "none", "primary": false}
  ],
  "min_samples": 100,
  "alpha": 0.05,
  "power_target": 0.8,
  "filters": {"all": []},
  "stratify_by": ["complexity"],
  "tags": ["ci-stability", "U2"],
  "notes": "pr_ci_wall_time and ci_run_failure_rate are new (U1). Merge-group failure rate is a guard: it may rise because failures move to the queue."
}
```

**E3 (U3, merge-group blame).**

```json
{
  "schema_version": 1,
  "key": "ci-stability-u3-merge-group-blame",
  "title": "Blame merge-group failures before ejecting",
  "hypothesis": "Fewer innocent PRs leave the merge queue, so PR open-to-merge time falls for feature tickets.",
  "owner": {"kind": "agent", "id": "executor"},
  "origin": {"kind": "manual", "ref": null},
  "status": "active",
  "design": {"kind": "before_after", "assign_by": "start", "change": {"type": "merge", "ref": "<merge-sha>", "time": "<merge-time>"}},
  "metrics": [
    {"ref": "delivery-speed/innocent_dequeues", "direction": "decrease", "primary": true},
    {"ref": "delivery-speed/pr_open_to_merge", "direction": "decrease", "primary": false},
    {"ref": "delivery-speed/reverts", "direction": "none", "primary": false},
    {"ref": "delivery-speed/main_red_events", "direction": "none", "primary": false}
  ],
  "min_samples": 60,
  "alpha": 0.05,
  "power_target": 0.8,
  "filters": {"all": [{"attr": "feature_tags", "op": "exists", "value": true}]},
  "stratify_by": ["epic"],
  "tags": ["ci-stability", "U3"],
  "notes": "reverts and main_red_events are guards against keeping a real regression in the queue."
}
```

**E4 (U4, quarantine on first base failure).**

```json
{
  "schema_version": 1,
  "key": "ci-stability-u4-quarantine-first-failure",
  "title": "Quarantine on the first base failure with owner and expiry",
  "hypothesis": "Main is red less often and fewer duplicate flake tickets are filed.",
  "owner": {"kind": "agent", "id": "executor"},
  "origin": {"kind": "manual", "ref": null},
  "status": "active",
  "design": {"kind": "before_after", "assign_by": "start", "change": {"type": "merge", "ref": "<merge-sha>", "time": "<merge-time>"}},
  "metrics": [
    {"ref": "delivery-speed/main_red_events", "direction": "decrease", "primary": true},
    {"ref": "delivery-speed/flake_issues_filed", "direction": "decrease", "primary": false},
    {"ref": "delivery-speed/flaky_failure_rate", "direction": "decrease", "primary": false},
    {"ref": "delivery-speed/reverts", "direction": "none", "primary": false}
  ],
  "min_samples": 14,
  "alpha": 0.05,
  "power_target": 0.8,
  "filters": {"all": []},
  "stratify_by": [],
  "tags": ["ci-stability", "U4"],
  "notes": "Day-level metrics: 14 days per arm."
}
```

**E5 (U5 and U6, isolation primitives, lint and leak guard).** Create one experiment for U5 and one for U6 with the same body and their own `key`, `ref` and `time`.

```json
{
  "schema_version": 1,
  "key": "ci-stability-u5-isolation-ratchet",
  "title": "Test-isolation primitives and lint ratchet",
  "hypothesis": "Fewer flaky failures, fewer test-fix tickets, and a larger share of merges that are feature work.",
  "owner": {"kind": "agent", "id": "executor"},
  "origin": {"kind": "manual", "ref": null},
  "status": "active",
  "design": {"kind": "before_after", "assign_by": "start", "change": {"type": "merge", "ref": "<merge-sha>", "time": "<merge-time>"}},
  "metrics": [
    {"ref": "delivery-speed/flaky_failure_rate", "direction": "decrease", "primary": true},
    {"ref": "delivery-speed/feature_merge_share", "direction": "increase", "primary": false},
    {"ref": "delivery-speed/flake_issues_filed", "direction": "decrease", "primary": false},
    {"ref": "delivery-speed/merged_per_hour", "direction": "increase", "primary": false},
    {"ref": "delivery-speed/rework_time", "direction": "decrease", "primary": false}
  ],
  "min_samples": 14,
  "alpha": 0.05,
  "power_target": 0.8,
  "filters": {"all": []},
  "stratify_by": [],
  "tags": ["ci-stability", "U5"],
  "notes": "Slow effect; read the confirmatory report after 28 days."
}
```

**E7 (U7, browser smoke path gate).**

```json
{
  "schema_version": 1,
  "key": "ci-stability-u7-browser-path-gate",
  "title": "Run browser smoke on PRs only for web changes",
  "hypothesis": "Fewer job-minutes per PR run, so queue waits at peak and PR CI wall time fall.",
  "owner": {"kind": "agent", "id": "executor"},
  "origin": {"kind": "manual", "ref": null},
  "status": "active",
  "design": {"kind": "before_after", "assign_by": "start", "change": {"type": "merge", "ref": "<merge-sha>", "time": "<merge-time>"}},
  "metrics": [
    {"ref": "delivery-speed/ci_queue_wait", "direction": "decrease", "primary": true},
    {"ref": "delivery-speed/pr_ci_wall_time", "direction": "decrease", "primary": false},
    {"ref": "delivery-speed/merge_group_failure_rate", "direction": "none", "primary": false}
  ],
  "min_samples": 200,
  "alpha": 0.05,
  "power_target": 0.8,
  "filters": {"all": []},
  "stratify_by": [],
  "tags": ["ci-stability", "U7"],
  "notes": "Merge-group failure rate is a guard: web regressions now surface in the queue."
}
```

**E8 (U8, tracked retries; only if Kevin approves).**

```json
{
  "schema_version": 1,
  "key": "ci-stability-u8-known-flake-retry",
  "title": "Retry known flakes once with tracking",
  "hypothesis": "Fewer PR CI reruns and less rework without more reverts.",
  "owner": {"kind": "agent", "id": "executor"},
  "origin": {"kind": "manual", "ref": null},
  "status": "active",
  "design": {"kind": "before_after", "assign_by": "start", "change": {"type": "merge", "ref": "<merge-sha>", "time": "<merge-time>"}},
  "metrics": [
    {"ref": "delivery-speed/ci_rerun_rate", "direction": "decrease", "primary": true},
    {"ref": "delivery-speed/rework_time", "direction": "decrease", "primary": false},
    {"ref": "delivery-speed/reverts", "direction": "none", "primary": false},
    {"ref": "delivery-speed/main_red_events", "direction": "none", "primary": false}
  ],
  "min_samples": 100,
  "alpha": 0.05,
  "power_target": 0.8,
  "filters": {"all": []},
  "stratify_by": [],
  "tags": ["ci-stability", "U8"],
  "notes": "Guards: reverts and main_red_events must not rise."
}
```

**E9 and E10 (U9 capacity, U10 local test policy).** Use E7's metrics for U9 (`ci_queue_wait` primary) and `start_to_pr_open` (decrease), `rework_time` (none, guard) and `ci_run_failure_rate` (none, guard) for U10, with change type `config` and the config change time.

Overlapping changes: if two remedies merge within 3 days of each other, the Executor records the second as a confounder annotation on the first experiment.

---


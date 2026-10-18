# Executor review CPU pressure comparison

## Result for 2026-10-18

This workspace could not run a controlled Executor-review comparison: no review
agent was active, and the Executor process had no per-process CPU sample. The
host showed `/proc/pressure/cpu some avg60=83.45%` at 19:27:45Z. The current
user-session cgroup was also about 83.18%, but includes unrelated user
processes, so it cannot attribute that pressure to review work. The dedicated
Stream Deck service cgroup was nearly idle (`some avg60=0.35%`). These are
observations, not evidence that Executor review caused the host pressure.

## Reproducible comparison

Run on the Executor host with an idle dispatch fleet and no unrelated workload
changes. Use a 10-minute baseline with Executor review stopped, then a
10-minute treatment with one representative review active. Repeat the pair in
reverse order to reduce time-of-day bias. Record UTC start/end, review process
identity and CPU time, `/proc/pressure/cpu` `some avg60` at one-minute samples,
`/proc/stat` CPU counters, and the review process's cgroup `cpu.pressure` and
`cpu.stat` deltas when available. Keep the host-wide PSI as the admission safety
signal; do not subtract cgroup PSI from host PSI because the signals overlap and
are not additive. Report both medians and the observed ranges for each phase.

The experiment is inconclusive until these controlled phases have actually been
run. The scheduler change should be evaluated separately from this measurement;
no review process was reniced or otherwise modified here.

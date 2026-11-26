# Executor review CPU pressure comparison

Use this procedure on the Executor host to compare host PSI with and without
Executor review work. Keep fleet dispatch and unrelated host workload stable.

1. Record a 10-minute baseline with Executor review stopped.
2. Record a 10-minute treatment with one representative review active.
3. Repeat the pair in reverse order to reduce time-of-day bias.
4. At one-minute intervals, record UTC time, host `/proc/pressure/cpu` `some`
   avg60, `/proc/stat`, review-process-tree CPU time from `/proc/<pid>/stat`
   (utime + stime), and fleet-process-tree CPU time over the same interval.
5. Record process identity, nice value, and cgroup `cpu.stat` / `cpu.pressure`
   when available. Report medians and ranges for both phases.

Do not subtract cgroup PSI from host PSI: the signals overlap and are not
additive. Record the comparison result in the PR body or ticket discussion so
the dated measurement does not become stale documentation.

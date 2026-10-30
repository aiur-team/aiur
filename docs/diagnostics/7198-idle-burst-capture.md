# Rare idle daemon burst capture

The last NUC reading after scheduler busy-wait was disabled had median 22.9%
and one maximum of 168% across 41 readings. No repeated culprit has been
established. This sampler prepares evidence for #7198; it makes no CPU saving
claim and does not establish the median <30% / max ≤150% acceptance gate.

Run from the Executor checkout on the NUC. Issue workspaces cannot observe
the host daemon. Do not start a replacement daemon, reset sandbox tickets,
or manufacture CPU load to reproduce this spike.

## Capture on the running release

Use the operator's existing release RPC connection to the intended daemon.
`release_bin` below must be that release's absolute `bin/aiur` path, with its
existing node/cookie environment. `sampler` is the absolute path to this
checkout's `scripts/diagnostics/idle_burst_sampler.exs`. Use a fresh, private
output file. Load and call the sampler **on the daemon**, not with `mix run`:

```sh
"$release_bin" rpc "Code.eval_file(\"$sampler\"); Aiur.Diagnostics.IdleBurstSampler.run() |> IO.inspect(limit: :infinity, printable_limit: :infinity)" > "$capture_file"
```

Loading the file starts nothing. The explicit call runs synchronously in the
RPC evaluator, observes for at most ten minutes (apart from time spent in
process-info calls or scheduler delays), and stops early after twenty bursts.
Run one sampler at a time. It does not change dispatch or VM settings.

Every 200 ms it reads reductions for all visible BEAM processes except itself,
then ranks deltas. For the top five processes exceeding 300k reductions per
200 ms, it takes eight stack samples at 25 ms intervals, sampling all five
together. Delayed windows use their actual elapsed time for the threshold.
Exited PIDs yield `nil`; new PIDs need a baseline before qualifying.

Each burst records the PID, registered name, initial call, reduction delta,
window duration, and timestamped stacks. Capture time is excluded by taking
a fresh baseline afterward. A deadline can truncate the eight-stack sequence;
the returned sample count makes this visible. The result reports elapsed time,
window count, and whether duration or the burst cap stopped capture.

All-process inspection adds overhead. Do not treat a profiled window as a clean
CPU acceptance reading. A reduction trigger can also miss work in native code
or a process that exits before its next poll; an empty capture proves neither
the absence of CPU spikes nor their cause.

## Interpret and validate

- Repeat capture only when convenient. Retain separate raw results and daemon
  commit, uptime, VM flags, agent counts, and host PSI for each window.
- Compare stacks across distinct bursts. A single stack, a registered name, or
  `gen_server.loop` alone is not evidence to bound a candidate path. Change a
  hot path only after the same culprit repeats with an identified work source.
- After a demonstrated fix, stop the sampler, settle for ten minutes, and take
  a separate standard reading: zero agents throughout, dispatch paused by the
  Executor, host CPU PSI <5%, and 41 × 15 s `top` samples for the daemon PID.
  Preserve all raw samples, identify the initial cumulative `top` sample, and
  report median, p75, and max with the same convention as the baseline.
- Acceptance remains median <30% and max ≤150%. If the only miss is another
  isolated spike, retain the evidence; do not claim the gate passed.

Do not publish captured stack locations without reviewing the output for local
paths. The sampler never reads process dictionaries or message contents.

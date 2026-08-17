# BEAM crash-dump triage

This record separates the seven dumps that prompted #1484 from later copies and
new crashes. A path count is not a crash count: on 2026-08-17 a recursive scan
found 272 dump paths but only 23 content hashes, largely because warm-base and
worktree copies multiplied ignored artifacts. A later depth-limited scan found
38 paths (37 `nodistribution`, one ToolCallLedger boot failure); those counts
describe a narrower live-corpus view, not a contradiction or seven new events.

## Original seven dumps

| Timestamp (UTC) | Processes | Slogan / family | Current process and stack | Disposition |
| --- | ---: | --- | --- | --- |
| 2026-07-30 20:59:19 | 11 | `cannot get bootfile .../start.boot` | `init` `<0.0.0>`; `init:boot_loop/2` → `erlang:halt/1` | Explained by release ERTS state crossing into a child build (#1404). `ERL_LIBS` was the remaining unconditional load-path leak. |
| 2026-07-30 21:38:12 | 11 | `cannot get bootfile .../start.boot` | `init` `<0.0.0>`; same boot stack | Same cause and fix. |
| 2026-07-30 21:51:37 | 11 | `cannot get bootfile .../start.boot` | `init` `<0.0.0>`; same boot stack | Same cause and fix. |
| 2026-07-30 21:57:26 | 11 | `cannot get bootfile .../start.boot` | `init` `<0.0.0>`; same boot stack | Same cause and fix. |
| 2026-07-31 07:32:18 | 51 | `badarg` in `io:put_chars(standard_error, ...)` | Dump-time process was `init` `<0.0.0>` in `init:boot_loop/2` → `erlang:halt/1`; the original writer and group leader were no longer present | A four-scheduler child BEAM, not the 16-scheduler daemon. Inheriting the daemon's `ERL_CRASH_DUMP` made the child impersonate a daemon capture. The dump proves the stderr device was absent but contains insufficient evidence to reconstruct the earlier writer/group-leader lifecycle. |
| 2026-07-31 16:22:26 | 101 | `badarg` in `io:put_chars(standard_error, ...)` | Dump-time process was `init` `<0.0.0>` in the same boot stack; the original writer and group leader were no longer present | Same child-BEAM classification and evidence limit. No current-corpus recurrence remained when #1499 was closed; the boundary fix is to keep daemon dump variables out of children, not to guard `io:put_chars`. |
| 2026-07-30 17:34:36 | 964 | `erl_child_setup: 104` | No active Erlang process or crashing stack remained; scheduler 2 was on `#Port<0.0>` | Native port-spawn helper failure (`104` is `ECONNRESET`). Insufficient evidence identifies the child, load condition, or ProcessReaper interaction, so the dump does not prove saturation or reaping as its cause. The bounded finding was carried into #1429/#1430 and the saturation measurement. |

The two stderr dumps were written hours after their child runs began. Their
small scheduler counts, dump-time `init` state, and inherited destination make
them child failures captured at a daemon-owned path rather than evidence that
the Aiur daemon lost its own stderr device.

## Family dispositions

### Release boot environment

#1404 correctly identified the bootfile family as release ERTS state leaking
across the agent boundary. #1521 subsequently made `ROOTDIR`, `BINDIR`, `EMU`,
and `PROGNAME` conditional on evidence that the Aiur launcher owns their values;
that condition deliberately preserves unrelated user OTP toolchains. Making
those generic variables unconditional would weaken that contract.

`ERL_LIBS` is different: it is a process-global BEAM library-path override and
has no safe child inheritance case here. #1484 therefore removes it
unconditionally, alongside daemon-only `ERL_CRASH_DUMP` and
`ERL_CRASH_DUMP_SECONDS`. The later depth-limited 38-path scan contained no
copy of the four original timestamps, but the wider corpus still contained 172
bootfile paths; copied artifacts make that path count unsuitable as a
post-fix recurrence signal. The same scan's 37 `nodistribution` dumps are a
separate distribution-startup symptom, not evidence that the bootfile cause
recurred. After this fix lands, the new crash-dump attention is the tracking
boundary: any newly completed bootfile dump will surface with its slogan and
can be classified as a fresh event instead of another copied path.

### Stderr lifecycle

The original dumps are insufficient to name the earlier writer or group
leader, and no matching `io:put_chars` dump remained in the later live-corpus
scan. This family is retired as daemon-instability evidence. #1499 recorded the
stderr investigation; #1484 prevents child BEAMs from writing future failures
to the daemon's dump path.

### Native spawn helper

The one `erl_child_setup: 104` dump is intentionally left as insufficient
process-level evidence. It remains useful as a historical port-spawn symptom,
but attributing it to saturation, churn, or a particular child would exceed
what the dump contains. See
[`2026-08-03-daemon-saturation-root-cause.md`](2026-08-03-daemon-saturation-root-cause.md)
for the later bounded reproduction and admission-control conclusion.

## Provenance and retention

The repository-root `erl_crash.dump` cannot be treated as a daemon crash. At
2026-08-02 06:14:29 UTC an Executor-side release-RPC probe for #1355 started
without the required distribution environment and overwrote that already
untracked path. Its prior contents are unrecoverable. Commit `15cdc513` later
made a root dump a tracked artifact, which also allowed copies to spread through
warm bases and worktrees.

The retention change removes that tracked artifact, ignores conventional
`erl_crash.dump` paths, and filters only ignored dump artifacts while staging a
new workspace. It does not recursively delete existing user evidence. New
daemon-owned dumps remain under the run log root; after an unexpected BEAM exit
the external watchdog records the bounded `Slogan:` and path in a durable
needs-attention alert so the next dump is triaged immediately.

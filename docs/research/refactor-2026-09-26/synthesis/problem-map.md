# Problem map: progress stalls and refactor pressure

This map is grounded in the [60-claim audit](verified-claims.md), the frozen
code review, and the feature challenge ledger. It separates observed stalls,
plausible mechanisms and structural constraints. The gaps overlap across repos
and time windows; the rows are not additive hours or predicted savings.

## Outcome and evidence boundary

The outcome to improve is **time without accepted ticket or PR progress while
work remains actionable**. The retained gap model counts 108 intervals of at
least 30 minutes and 727.73 exact hours. Five very long intervals account for
447.86 hours. That concentration makes average cadence and single-command
speed insufficient success measures. The data cover different repository and
provider windows, and a gap does not by itself identify who could have acted.

| Layer | What is observed | What remains uncertain | Design consequence |
| --- | --- | --- | --- |
| Human and permissions wait | A current-era khala window of about 18.9 hours was labelled stranded although four agents were dispatched and waiting on repository write access. Their labels remained `agent:todo` because the agent identity could not write them. | The historical classifier's full `b/c` hours are precedence-assigned bins, not a causal human share. | Model waiting causes from agent state, authority and requested decision, not from tracker label alone. Keep operator action and delivery visible. |
| Parked rework | aiur #2678 remained undispatched for about 15.7 hours after the daemon restored `rework` while a lifecycle fence was open. The dispatcher admitted it on repeated polls; other tickets dispatched. khala #46 adds about 2.8 hours with a similar shape but weaker mechanism evidence. | The current-era true stranded estimate is about 18.5 hours plus 1.1 unverified hours; its broader incidence is unknown. | Give ticket lifecycle one owner. Make parked entries, fences and redispatch decisions observable, durable and testable together. |
| Agent continuation | 12,768 of 22,613 retained agent turns were normal continuations with at most one tool call. Their measured turn time was about 20 hours, not the inherited 186 hours. A few threads dominate. | Token and account-pressure impact varies by provider and context size; one khala loop moved a shared Claude limit earlier but was not its sole cause. | Stop sending a normal continuation simply because a tracker state remains active. Wait on a concrete external condition and wake on a relevant event or bounded timer. |
| Wake ownership | Durable Executor cursors lagged or stopped while notification-only monitoring continued. Above-cursor records are unacknowledged, not necessarily unseen. Some alert classes re-asked the same condition every 15 minutes. | Whether the human or agent acted on each notification requires action records, not cursor position. Historical storms were largely pre-fix. | Unify observation, acknowledgement and action receipts without conflating them; retain backlog and overflow visibility. Avoid periodic duplicate attention. |
| Build/deploy identity | Dev and installed CLIs, checkout HEAD, release stamp and running daemon can differ. The shim already rebuilds for selected paths; control commands intentionally reuse the running release. | The incidence of wrong-build operations in the current fleet has not been counted. | Present source/release/process identities together, and make restart confirmation a first-class acceptance gate. Do not use a source commit alone as deployment proof. |
| GitHub read and budget policy | Typed local budget holds exist, but callers handle them differently. Large responses can be emptied under a success status. Webhooks widen selected polling only after verified delivery; failed delivery leaves full reconciliation polling. | No saving follows from classification alone or from a disabled config. Current webhook failures need their own diagnosis. | Centralize typed read outcomes and per-resource freshness; count affected live populations and measure actual credential-side saving before claiming it. |
| Review and decision flow | Rework state has multiple writers, and a completed answer can be superseded only before delivery. PR reviews, CI and operator authority occupy distinct states. | Selected fix histories show failures, not a comparative proof that one monolith or one package layout caused them. | Move state transitions behind one authority while retaining explicit review-thread, own-diff, version and delivery checks. |

## Structural causes that amplify recovery cost

The survey and independent AST scan put 35 of 36 proposed boundaries in one
source-reference component. That graph is a design warning, not a runtime call
graph or proof that extraction is impossible. The Orchestrator keeps a
100-field state struct and central dispatch, control and CI reducers in one
GenServer. It also has a synchronous control-mutation path that can queue
behind work in its mailbox, while read-only status uses a separate view.
Those ownership and contention facts are stronger design evidence than a raw
module count. See `codebase-02`, `codebase-04` and `codebase-09`.

The frozen tracked-file census counts 359 UTF-8 text files above 500 physical
lines, including 109 under `src/lib` and 136 under `src/test`. A hard 500-line
rule requires a staged decomposition and an automated gate; splitting a file
without separating responsibility, or moving it to another package, does not
reduce the failure surface. The target is no newly enlarged files, then zero
tracked text files above 500. Prefer 200 or fewer lines per file where
cohesion permits. The exact census and migration terms are in
[file-size-analysis.md](file-size-analysis.md).

## Working hypotheses to validate before choosing package borders

1. A lifecycle owner that atomically interprets tracker state, provider
   delivery, fences, CI and review evidence should reduce stranded rework.
   Validate on recorded #2678/#46 timelines and intentionally failed writes,
   then measure future stranded intervals. This is a hypothesis, not a claimed
   hour saving.
2. A condition-driven agent wait should reduce redundant continuation turns.
   Validate on real provider turn streams and the top concentrated sessions;
   count turns and account limit events before calling it a saving.
3. One durable Executor attention/read/acknowledge contract should reduce
   unowned requests and repeated re-asks. Validate against actual action
   completion, not cursor advancement alone.
4. Package extraction should follow stable authority and data contracts. Test
   the intended edges with real CLI/TUI and GitHub failure paths before moving
   code; graph decoupling and physical LOC reduction are separate outcomes.

## Measures for a later implementation

- **Progress:** number and duration of no-progress intervals with actionable
  demand, using a definition that records active agents, waiting decisions,
  permissions and tracker freshness.
- **Redispatch:** time from actionable rework evidence to accepted dispatch,
  plus count of parked entries and open fences by cause.
- **Continuation:** redundant normal continuation turns and their measured
  provider tokens by backend, with an unchanged acceptance/throughput guard.
- **Attention:** distinct open conditions, receipts, unacknowledged wakes,
  repeat re-asks and time to actual resolution; do not equate acknowledgement
  with action.
- **Change safety:** CI and real TUI acceptance, typed failure states, and
  tracked-file-size compliance. Any quota or latency saving later claimed must
  include a running-system baseline, actual population and merge-time gate.

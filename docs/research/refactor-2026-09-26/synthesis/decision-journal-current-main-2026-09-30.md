# Decision journal and projection at `main@b4bc11f`

Two independent read-only reviews checked KTD10 against detached
`b4bc11ffcb6abf693bb3c8570aca3e12d82cb24f`. This is source evidence,
not a runtime test. It confirms and sharpens the earlier
[U6 outcome matrix](u6-decision-journal-outcome-matrix-2026-09-29.md),
rather than claiming newly discovered incidents. A successful append already fsyncs the canonical
`decisions.ndjson` record (`decision_log.ex:127-145`). Boot replays it and
repairs `decisions.json` (`decision_store.ex:624-653`). A complete invalid
transition makes the store read-only; an incomplete tail is truncated and
synced. A well-formed event from a newer binary is retained and skipped
without being called corrupt (`decision_store.ex:660-714`,
`decision_log.ex:170-193`).

| Current-main gap | Evidence | Focused proof before implementation |
| --- | --- | --- |
| A post-write sync error is indistinguishable from a pre-write failure. | `DecisionLog.append/2` can write a complete line before `:file.sync` returns an error (`decision_log.ex:127-145`). The request and lifecycle callers return an error with their prior in-memory state (`decision_store.ex:2426-2462,2483-2507`); a same-process retry can reserve a different event ID for the same transition. | Inject failure before write and after full write/before confirmed sync. Reconcile the journal and event identity before retry, then assert one accepted transition on the same process and after restart. |
| Projection failure is treated as loss of write authority. | `repair_projection/1` marks `writable?: false` and `health: {:repair, reason}` after a confirmed append (`decision_store.ex:733-751`); the request still returns accepted (`decision_store.ex:2426-2459`). No runtime repair/replay path or observed age was found. | Force projection write failure after a confirmed journal append. Assert accepted event/read model, explicit stale cause and age, repair from journal without a duplicate event, and correct write/side-effect policy during repair. |
| Request notification crosses the stale-projection boundary. | `persist_and_notify` passes the pre-repair state to `notify/3` unconditionally (`decision_store.ex:2456-2459`), which publishes Exchange, Executor-request and PubSub notifications (`decision_store.ex:4603-4621`). Lifecycle notification and answer dispatch have writable guards (`decision_store.ex:2509-2527,3827-3835`). | Subscribe to each request output, fail projection replacement, and assert the chosen policy per side effect, including replay by persisted event ID after repair. Do not silently suppress a durable accepted request. |
| Blocking reads and withheld events need distinct recovery. | Blocking-ticket readers report store unavailable in repair health (`decision_store.ex:1064-1094,1771-1778`). Boot reconciliation runs only when writable and requested reconciliation scans open/deferred decisions (`decision_store.ex:597-611,2596-2613`); there is no general replay of withheld lifecycle topics there. | Keep dispatch fail-closed until blocker reads can use journal-authoritative state. Fail an accepted answer's projection write, restart after repair, then assert exactly one original-ID lifecycle publication and dispatch; include a terminal event outside open/deferred scans. |
| Existing tests cover only part of the failure matrix. | Torn-tail and complete-corruption tests exist (`decision_log_test.exs:113-188`, `decision_store_test.exs:4408-4568`). Projection tests assert repair health and answer-dispatch suppression (`decision_store_test.exs:3284-3297,4571-4589`), not request notification identity or restart recovery. | Add deterministic append/projection failure seams; verify the new tests fail with the production fix reverted. Existing chmod-based failure tests may vary by execution user. |

Keep KTD10's distinction between authoritative journal and rebuildable
projection, but specify which side effects may run when the projection is
stale. Do not turn all append errors into safe retries or all complete
unrecognized records into corruption.
`decisions.json` lacks an event high-water mark and generated timestamp
(`decision_projection.ex:908-915`), so file mtime alone cannot prove that it
contains the latest accepted event.

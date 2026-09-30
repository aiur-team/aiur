# Opencode slot seed and host coupling at `main@b4bc11f`

This static re-trace covers provisional P2 `agent-backends-oc-18` against the
detached `b4bc11ffcb6abf693bb3c8570aca3e12d82cb24f` source tree. It
checks the finding's proposed shortcut—seed the slot from
`AttachPool.seed/3` instead of polling Orchestrator—before treating a new
`Opencode.Host` port as a worker-ready refactor. No runtime timing or incident
count was measured.

## Current path and bound

`SlotPolicy` starts all configured warm slots in its `:start_all_slots`
callback (`slot_policy.ex:201-229`). A new `Slot` starts with an empty
`known_identifiers` set (`slot.ex:165-174`, `slot/state.ex:38`), and its
`:start_serve` continuation calls
`ServeLifecycle.safely_list_active_identifiers/0` when that set is empty
(`slot.ex:183-193`, `slot/state.ex:83-97`). The lifecycle polls
`Orchestrator.list_active_identifiers/2` and sleeps 100 ms after an empty
result until its **sleep-count** reaches 3,000 ms
(`slot/serve_lifecycle.ex:29-34,269-288`). Every fetch has a 500 ms RPC
timeout; `StatusReport.list_active_identifiers_api/2` catches that timeout
and returns an empty list (`orchestrator/status_report.ex:133-143`). Thus the
nominal 3-second budget permits 30 fetches plus the final fetch. If every
fetch exhausts its timeout, source constants permit about **18.5 seconds**
inside one Slot callback (31 × 500 ms + 30 × 100 ms), before serve startup.
This is a static upper bound for that path, not an observed startup delay.
The newer serve retry delays of 250 and 500 ms occur *after* identifier
selection (`slot/serve_lifecycle.ex:11,81-94`) and do not bound this wait.

`AttachPool` does have `active_identifiers`, but it starts with an empty list
and receives an asynchronous seed cast only after `AgentList.App` handles a
`:running_changed` event (`attach_pool.ex:46,87-91,190-192`,
`agent_list/app.ex:170-173,318-325`). The interactive supervisor lists
`PrewarmSupervisor` before `AgentList.App` (`aiur.ex:258-264`), and
`PrewarmSupervisor` starts `SlotPolicy` before `AttachPool`
(`opencode/prewarm_supervisor.ex:24-32`). There is no seed payload in the
slot's initial state and no synchronizing handoff from the pool to its
`:start_serve` continuation. Consequently, simply replacing the
Orchestrator query with the pool's current list can produce an empty models
map at boot. The slot comments explicitly say that a later identifier miss
rebuilds the serve, so this can exchange a warm first open for a cold rebuild
(`slot/state.ex:35-47`). The existing state tests cover selection of
`:poll_orchestrator` versus already known IDs, not seed ordering
(`slot/state_test.exs:249-264`).

## Refactor decision gate

The direct Orchestrator call and the other host couplings cited by
`agent-backends-oc-18` still exist, but the finding's proposed pool-seed
shortcut is incomplete. Keep this P2 as a provisional fix, scoped first to
the slot startup contract. Before removing the poll, supply an explicit,
generation-aware identifier handoff or prove another source is available
before each slot boots. Test three orders: active IDs arrive before slot
start, after slot start but before serve materialization, and only after an
empty serve is ready. Assert the first open's warm/cold behavior and that a
late or stale seed cannot remove an already known identifier. A stalled
Orchestrator call should also demonstrate a real elapsed wall-clock bound
that covers RPC time as well as sleeps. Only then consider a host port for
the remaining independent calls; this trace does not establish a need for a
new package or quantify a saving.

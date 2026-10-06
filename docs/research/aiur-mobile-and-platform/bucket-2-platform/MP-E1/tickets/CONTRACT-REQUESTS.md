# MP-E1 contract requests (for the coordinator)

MP-E1 owns `contracts/queue-readiness-and-build-progress.md` and updated it in
Phase C (RC-08, RC-10, RC-11, RC-19, RC-20). The items below touch documents
that MP-E1 does **not** own.

| # | Document (owner) | Request | Why |
| --- | --- | --- | --- |
| CR-1 | `contracts/events-and-replay.md` §9 (MP-R2) | Change "`system.build_order.<root>.*` (… producer owned by build orders)" to name **MP-E1-C7** as the producer (RC-08), and list the exact topics `system.build_order.<root>.progress` and `system.queue.<queue_id>.progress` (milestones), `ticket.<id>.queue.{promoted,withdrawn,held,released,overridden,removed}`, `ticket.<id>.queue.attention.<cause>[.resolved]`, `system.queue.attention.<cause>[.resolved]`. | The contract still says build orders own the producer; RC-08 settled it. |
| CR-2 | `contracts/events-and-replay.md` §11 MP-E1 row (MP-R2) | The queue does not need `ticket.<id>.pr.closed_unmerged` or a `blocked_by changed` event: it reads the `:branch_pull_request` deposit and the bounded `blocked_by` read through tracker callbacks. The topics stay registered (RC-08) as optional triggers. | Avoid R2 building a producer on MP-E1's critical path. |
| CR-3 | MP-R1 `component-map.md` §3/§4 (MP-R1) | Record that the `tracker` component's `Aiur.Tracker` behaviour gains five optional callbacks used by the queue: `open_issue_labels/1`, `blocked_by/1`, `issue_closure/1`, `ticket_pull_request/1`, `ensure_labels/1` (GitHub implements; Linear answers `:unsupported`). | This is how `build_queue/` reads GitHub facts without referencing `Aiur.GitHub.*`; no new component edge beyond RC-11's two. |
| CR-4 | MP-R1 `component-map.md` (MP-R1) | Place the neutral `Aiur.BuildProgress` module (`src/lib/aiur/build_progress.ex`) and `Aiur.BuildOrder.ProgressObserver` (`build_order/progress_observer.ex`) in the map: BuildProgress belongs with `build-queue` (or its own small component); the observer belongs to `build-orders`. | RC-10 progress API; consumed by MP-N3/N5/N7. |
| CR-5 | Prior plan U2 (refactor plan, `docs/plans/2026-09-29-001-…`) | U2's ticket-transition owner names the queue as owner of the marker-only ↔ todo transition, and keeps `expected_state: :none` (MP-E1-C1-T04) on U2's writer. | RC-20 and plan §10. |

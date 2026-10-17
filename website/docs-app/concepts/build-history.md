# Continuous build history

A repository has one continuous build. Feature collections group work added over
time: a new feature, epic, bug batch, or experiment joins the existing build,
with its research and design evidence preserved. Existing [Build Order
roots](./build-orders) remain readable history and import as `bo-<number>`
features; new features do not need another root.

## Adding work

The Executor files authorized work with `feature:<slug>` labels, registers its
owning collection through [feature commands](../reference/build-history-commands#features),
writes native `blocked_by` links for real prerequisites, and adds executable
tickets to the [build queue](./ticket-lifecycle#build-queue).

Prerequisites can
cross collection boundaries. Feature membership groups tickets; queue membership
schedules them when their prerequisites clear.

These are separate writes. Intake is complete only after the Executor reads back
the collection, projected labels, prerequisite links, queue membership, and order.

Until the continuous Build view is available, `aiur feature show <slug> --json`
and `aiur queue show --json` provide the checks; `aiur build-orders` reads legacy
roots. Unknown or stale evidence does not prove placement.

Only an explicit operator exclusion leaves filed work outside the build, parked
with `needs-triage` or `human:todo` and the reason. This default does not authorize
the Executor to file unsolicited work or expand a feature's acceptance boundary.

## Prioritizing work

“Prioritize” or “pull ahead” means place the new work before the previous next-up
using both a priority label and queue ordering. The Executor reports what it
displaced and verifies effective start order.

Within a list it adjusts ticket
positions; across lists it adjusts set ranks, which requires
`build_queue.set_order: ranked`. See [queue commands](../reference/cli#dashboard-page-commands).

Priority preserves real prerequisites, holds, and running agents. When a blocker
prevents immediate pickup, the Executor reports that constraint and the next
eligible work instead of claiming the new collection will start immediately.

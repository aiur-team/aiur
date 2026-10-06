---
design_task: DESIGN-E1
feature_id: MP-E1
owner: Kevin
status: open (awaiting explicit approval)
blocks: every MP-E1 implementation ticket (MP-E1-C1..C9)
shared_with: DESIGN-N3 (queue/build-progress counts on the meta-dashboard), DESIGN-N5 (progress milestone notifications)
base_main_sha: 45a290e3
date: 2026-10-06
related_plan: ../bucket-2-platform/MP-E1/plan.md
related_contract: ../contracts/queue-readiness-and-build-progress.md
---

# DESIGN-E1 — Kevin: design and approve the build-queue surfaces and rules

**Implementation of MP-E1 is blocked until this task is approved.** Research and
planning may continue. Do not mark this task complete without Kevin's explicit
written approval.

## 1. What you are designing

The build queue keeps the agent pool supplied. You, or your Executor, put
tickets in an ordered list, or adopt a Build Order root. The queue adds
`agent:todo` to every member whose prerequisites are complete. The existing
dispatcher still decides when each ticket starts.

You design three surfaces:
1. **The CLI output**: what each queue command prints, and the `--json` shape
   (which follows the contract).
2. **A read-only dashboard view**: you can see the queue, but you cannot edit it
   from the dashboard (D7).
3. **How queue state looks on GitHub**: the marker label.

You also decide seven rules the plan could not settle from evidence.

## 2. Decisions that need your input

| # | Decision | Recommendation | Why |
| --- | --- | --- | --- |
| OQ-1 | Where an explicit list position sits in the start order. D3 fixes critical path → priority → age | critical path → priority labels → **list position** → age | Keeps D3's first two keys; list position is the most specific order you gave |
| OQ-2 | Does a prerequisite closed as **not planned** fail (hold dependents and alert) or satisfy? | **Fail** | Matches the Build Order view. Today the dispatcher releases dependents |
| OQ-3 | Promote a ready ticket that carries `agent:paused`, `agent:parked`, `needs-triage` or `human:todo`? | **No.** Show it as "held by marker" | Those labels mean you parked it on purpose |
| OQ-4 | The name of the GitHub marker for "in the queue, not yet ready" | `agent:queued` | Visible on GitHub, and counts as your triage when you apply it. Note: `aiur units --condition queued` already means "has `agent:todo`". The alternative is `agent:waiting` |
| OQ-5 | Also write "after #N" edges as GitHub issue dependencies? | **No** for v1 | Keeps local plans out of the shared graph. Revisit later |
| OQ-6 | Is the queue on by default? | **Yes** | An empty queue makes no API calls and changes nothing |
| OQ-7 | Change the aiur-build and aiur-run conventions so waiting members are created with the marker instead of `agent:todo`, and make adopting a pre-labelled Build Order withdraw `agent:todo` from its blocked members? | **Yes and yes** | Otherwise `agent:todo` keeps meaning "maybe ready" |

## 3. CLI (`aiur queue …`)

Draft verbs (from D7), for you to approve or rename:

| Command | Effect |
| --- | --- |
| `queue add <ids…> [--after N] [--queue NAME] [--at POS]` | Add tickets to a list; `--after` adds "after #N" edges |
| `queue add --build-order <root>` | Adopt a Build Order root |
| `queue remove <ids…>` | Dequeue; removes the marker |
| `queue reorder <id> --to POS` | Move within a list |
| `queue hold <id\|--queue NAME>` | Stop promotion |
| `queue release <id\|--queue NAME>` | Resume promotion; also resumes an overridden or externally held item |
| `queue show [--queue NAME] [--json]` | Read model |
| `queue recover`, `queue clear --remove-markers` | Recovery and rollback |

For each command, design:

- **Human output.** A table or list layout. Columns to consider: position,
  ticket, title, state, waiting-on, rank reason, age of the data.
- **Success, partial-success and refusal messages.** Refusals include: not a
  label-capable tracker, ticket already in another queue, ticket closed,
  refused inside an agent workspace, store unavailable.
- **How stale or unknown data is printed.** Every surface shows `observed_at`
  and age. `unknown` must never print as 0 or as "ready".
- **Exit codes:** 0 on success, non-zero on refusal, and 124 when the outcome
  is unknown, matching `aiur message`.

## 4. Dashboard view (read-only)

**Placement:** a new `/queue` page, or a panel on `/build-orders`. Decide which.
If it is a new page, it must be added to the sidebar and the docs nav.

Show:
- each queue, its progress (the same percent as Build Orders), and its items in
  start order;
- each item's state chip (contract §2.3) and what it waits on (prerequisite
  numbers with their verdicts);
- why it is ranked where it is (open downstream count, priority, position);
- the attentions open against it, and the age of the data.

States to design:

| State | What it covers |
| --- | --- |
| Loading | The first read model is not yet available |
| Empty | No queues; show how to start one (CLI hint) |
| Disabled / unsupported tracker | Distinct copy for each |
| Stale | A source is older than its freshness bound; show the age, and dim the derived readiness |
| Unknown | A source is unavailable; readiness shows "unknown", not "waiting" or "0" |
| Error | Store unavailable, or writes paused by the GitHub budget |
| Item-level | waiting, promoted, promoted (unauthorized), claimed, held, overridden, failed prerequisite, completed, cancelled, removed |
| Success / resolved | An attention that has cleared; how long it stays visible |
| Permission-denied | Not applicable to the read-only view; the dashboard's existing auth applies |
| Offline | Same as the dashboard's existing disconnected state |

## 5. Attention copy

Write the alert-feed text for each of these:
- failed prerequisite: one alert naming the prerequisite, its cause, and every
  blocked ticket
- dependency changed after work started
- promoted but unauthorized
- merged PR, but the issue is still open
- inputs unavailable
- store unavailable
- label write failing

For each, decide what the Executor should be told to do.

## 6. Acceptance conditions

- [ ] OQ-1..OQ-7 are each answered.
- [ ] The CLI output for every verb, in the success, refusal, stale and unknown
      cases, is approved, as text mock-ups.
- [ ] The dashboard view's placement, layout and every state in §4 are
      approved, as screens or a clickable mock.
- [ ] The attention copy in §5 is approved.
- [ ] The marker label name and colour are approved.
- [ ] Kevin's explicit written approval is recorded here with a date.

Approval: _pending_

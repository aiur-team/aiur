# Progress emits & operator check-ins

## Progress emits — a 1-of-10 estimate at phase boundaries

The operator's only at-a-glance signal for "how far is each agent" is the progress
bar in the agent list. Populate it by emitting the bare `progress` event with a
numeric percent. The bar is 10 cells wide; each 10% step fills one cell.

**When to emit.** Once at the start of every phase boundary you cross —
`brainstorm`, `plan`, `work`, `review`. Pair the progress emit with the matching
`emit_alert("phase.<name>.start" | ".end", ...)`. Roughly 8 emits over a ticket's
life, plus rare mid-phase corrections. Hard cap: 2 emits per turn; the 3rd is
rejected.

**How to estimate.** Time-based, not output-based. Estimate the wall-clock
distance from "ticket started" to "PR ready for human review and CI green",
**including the cleanup tail**: review iterations, CI fixes, rework. Review + CI
often account for ⅓ or more of the total.

**The 1/10 scale.** Allowed values are `10, 20, …, 100`:

- `10`–`20`: brainstorming / planning
- `30`–`50`: implementation in flight
- `60`–`80`: code typed, in self-review or CI
- `90`: PR pushed, last fixes / final review pass
- `100`: emit exactly **once**, right before you flip the label to
  `agent:human-review` — regardless of which CE phases ran. This greens the
  operator's bar and tells Aiur to release your agent slot. Paths that skip
  brainstorm/plan/review still emit the 100% sample at the label flip. Don't emit
  100 before the label flip.

**The `label` field.** Names your cleanup-aware tail (≤ 80 chars). Format:
`"<phase>: <what you're doing now>, <tail you're budgeting>"`.

**Mid-phase corrections.** Rare. Re-emit only when your estimate shifts ≥ 15
percentage points OR by ≥ 50% of the remaining-time estimate.

**Worked example.** Starting `work` on a typical complexity:3 ticket:

```
emit_alert("phase.work.start", "implementing the rename")
emit_event(name: "progress", payload: %{
  percent: 30,
  label: "work: starting impl, ~2 review rounds + CI tail budgeted"
})
```

Just before `gh pr ready`:

```
emit_alert("phase.review.end", "PR ready for review")
emit_event(name: "progress", payload: %{
  percent: 100,
  label: "review: PR ready, awaiting human review"
})
```

## Operator check-ins (`operator.progress_request`)

Every five minutes Aiur publishes `operator.progress_request` to each active
agent. You see it as one event line in the digest at the next turn boundary —
never mid-tool-call. Reply with a single `emit_event`:

```
emit_event(name: "progress.checkin", payload: %{
  percent: <N * 10>,
  label: "<phase>: <what you're doing now>, <tail you're budgeting>"
})
```

Rules:

- `percent` is your **current** 1-of-10 estimate as `N * 10` (a "6 of 10" sends
  `60`).
- The check-in **trumps** any prior phase guess, even when it lowers the bar.
- Do not change your work plan, ask the operator anything, or narrate the ping in
  chat. It's a silent status request.
- One check-in per request. If two arrived in the same digest, reply to the most
  recent, then continue what you were doing.

# U-unit dependency edges

New edges to add to `dependency-graph.json`. Generated from the ticket front matter
(inbound) and from the MP-R interlocks (outbound). Every MP ID below exists in the
graph at the time of writing (checked by script). Kinds: `TICKET` (U to U),
`GATE` (U0 review gate, RC-19), `PRIOR` (replaces a pseudo-predecessor),
`CONFLICT` (same files; order only), `OWNER` and `EXTERNAL` (non-ticket blockers).

## Replaced pseudo-nodes

After adding these edges, remove the old pseudo-nodes from the graph:
`U2`, `U3`, `U5`, `U6`, `RQ-U2-TRANSITION`, `RQ-U6-STATUS-MODEL` (their edges are
re-pointed to real tickets below). Keep `U8` edges until the U8 tickets exist.
Update the `blocked_by` front matter of each MP ticket named in column "to" the same way.

## Outbound: U ticket blocks MP ticket

| from | to | kind | why | replaces |
| --- | --- | --- | --- | --- |
| U0-T01 | MP-R1-C1-T01 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R1-C2-T01 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R2-C1-T01 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R2-C1-T02 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R2-C1-T03 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R2-C1-T04 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R2-C1-T05 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R2-C1-T06 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R2-C2-T04 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R2-C4-T05 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R2-C6-T01 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R3-C1-T01 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R3-C2-T01 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R4-C1-T01 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R5-C1-T01 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R5-C4-T01 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R5-C4-T02 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R6-C1-T01 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R7-C1-T01 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R7-C1-T02 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R7-C1-T03 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T01 | MP-R7-C5-T02 | GATE | RC-19 U0 review gate (was text only) | - |
| U0-T02 | MP-R1-C11-T01 | PRIOR | size-owner lookup input (RC-23) | - |
| U2-T01 | MP-R1-C7-T07 | PRIOR | U2 lifecycle owner | U2-lifecycle-owner |
| U2-T01 | MP-R1-C7-T08 | PRIOR | U2 lifecycle owner | U2-lifecycle-owner |
| U2-T01 | MP-R1-C9-T06 | PRIOR | names the transition owner and state_writer | RQ-U2-TRANSITION, U2 |
| U2-T01 | MP-R1-C9-T09 | PRIOR | owner module, replay and failure rule | RQ-U2-TRANSITION, U2 |
| U2-T01 | MP-R1-C9-T07 | PRIOR | :lifecycle owner row maps to TicketTransition | - |
| U2-T01 | MP-R1-C9-T13 | CONFLICT | --todo call site rewired by U2-T01 | - |
| U2-T01 | MP-R1-C5-T06 | CONFLICT | same 22 orchestrator files | - |
| U3-T01 | MP-R2-C2-T01 | PRIOR | ordered replay before the Delivery seam | U3-event-subscription-delivery |
| U3-T02 | MP-R1-C9-T11 | PRIOR | stable Claims API | U3 |
| U3-T03 | MP-R1-C9-T11 | PRIOR | stable wake inbox API | U3 |
| U3-T03 | MP-R2-C2-T10 | CONFLICT | Executor callers of events facade | - |
| U4-T03 | MP-R1-C5-T02 | CONFLICT | tree-kill helper used before it moves to kernel | - |
| U4-T03 | MP-R7-C4-T04 | CONFLICT | claude/codex adapter files move after the fix | - |
| U5-T02 | MP-R2-C2-T02 | PRIOR | KTD9 trust snapshot (RC-21) | U5 (KTD9 ...) |
| U5-T04 | MP-R1-C7-T04 | PRIOR | typed outcomes | U5-typed-outcomes |
| U5-T02 | MP-R1-C7-T06 | PRIOR | full U5 exit | U5-typed-outcomes |
| U5-T04 | MP-R1-C7-T06 | PRIOR | full U5 exit | U5-typed-outcomes |
| U5-T04 | MP-R1-C7-T08 | PRIOR | typed outcomes | U5-typed-outcomes |
| U5-T04 | MP-R1-C8-T07 | PRIOR | GitHub access contract | U5 (prior unit, GitHub access contract) |
| U5-T04 | MP-R1-C8-T08 | PRIOR | Build Order membership contract (X-60) | U5 Build Order membership |
| U5-T02 | MP-R1-C9-T01 | PRIOR | U5 access-layer PRs merged | U5 |
| U5-T04 | MP-R1-C9-T01 | PRIOR | U5 access-layer PRs merged | U5 |
| U5-T04 | MP-R4-C1-T01 | CONFLICT | same doc page apis/github.md | - |
| U6-T01 | MP-R1-C5-T01 | PRIOR | journal outcome matrix before rename | U6-decision-journal |
| U6-T01 | MP-R1-C8-T02 | PRIOR | journal outcome matrix | U6 journal outcome matrix (prior unit) |
| U6-T01 | MP-R2-C3-T01 | CONFLICT | Events.Journal over the same DecisionLog | - |
| U6-T02 | MP-R1-C8-T01 | CONFLICT | Commands facade over decision_store.ex | - |
| U6-T04 | MP-R1-C9-T14 | PRIOR | shared status read model | RQ-U6-STATUS-MODEL, U6 |
| U6-T04 | MP-R1-C9-T10 | CONFLICT | agent_control_cli.ex renderers | - |
| U7-T01 | MP-R1-C7-T01 | PRIOR | Linear decision decides null code-host stubs | - |
| U7-T01 | MP-R7-C4-T02 | PRIOR | REPL/RC keep decision fixes adapter scope | - |
| U7-T02 | MP-R1-C7-T02 | PRIOR | if Linear is cut, registry shrinks | - |
| U9-T01 | MP-R1-C11-T03 | PRIOR | census is the refresh endpoint | - |
| U9-T02 | MP-R1-C11-T03 | PRIOR | proven integrated main | - |
| U9-T02 | MP-R1-C10-T05 | PRIOR | proven final release before go-live | - |

## Inbound and internal: predecessors of U tickets

| from | to | kind |
| --- | --- | --- |
| U0-T02 | U0-T01 | TICKET |
| U0-T01 | U1-T01 | TICKET |
| U0-T01 | U1-T02 | TICKET |
| U0-T01 | U1-T03 | TICKET |
| U0-T01 | U2-T01 | TICKET |
| U1-T01 | U2-T01 | TICKET |
| U1-T02 | U2-T01 | TICKET |
| U1-T03 | U2-T01 | TICKET |
| MP-E1-C1-T02 | U2-T01 | TICKET |
| MP-E1-C1-T03 | U2-T01 | TICKET |
| MP-E1-C1-T04 | U2-T01 | TICKET |
| U0-T01 | U2-T02 | TICKET |
| MP-E1-C1-T02 | U2-T02 | TICKET |
| U0-T01 | U2-T03 | TICKET |
| U2-T01 | U2-T03 | TICKET |
| U0-T01 | U2-T04 | TICKET |
| U0-T01 | U2-T05 | TICKET |
| U2-T04 | U2-T05 | TICKET |
| U0-T01 | U3-T01 | TICKET |
| U0-T01 | U3-T02 | TICKET |
| U0-T01 | U3-T03 | TICKET |
| U3-T02 | U3-T03 | TICKET |
| U0-T01 | U4-T01 | TICKET |
| U2-T01 | U4-T01 | TICKET |
| U0-T01 | U4-T02 | TICKET |
| U2-T01 | U4-T02 | TICKET |
| U3-T01 | U4-T02 | TICKET |
| U0-T01 | U4-T03 | TICKET |
| U0-T01 | U5-T01 | TICKET |
| U0-T01 | U5-T02 | TICKET |
| U5-T01 | U5-T02 | TICKET |
| U0-T01 | U5-T03 | TICKET |
| MP-E1-C1-T01 | U5-T03 | TICKET |
| U0-T01 | U5-T04 | TICKET |
| U5-T03 | U5-T04 | TICKET |
| U0-T01 | U6-T01 | TICKET |
| U0-T01 | U6-T02 | TICKET |
| U6-T01 | U6-T02 | TICKET |
| U0-T01 | U6-T03 | TICKET |
| U0-T01 | U6-T04 | TICKET |
| U2-T04 | U6-T04 | TICKET |
| U0-T01 | U6-T05 | TICKET |
| U0-T01 | U7-T01 | TICKET |
| U7-T01 | U7-T02 | TICKET |
| OWNER: Kevin approves the Linear cut | U7-T02 | OWNER |
| U5-T04 | U7-T02 | TICKET |
| U0-T03 | U9-T01 | TICKET |
| U9-T01 | U9-T02 | TICKET |
| U9-T03 | U9-T02 | TICKET |
| U1-T01 | U9-T02 | TICKET |
| U1-T02 | U9-T02 | TICKET |
| U1-T03 | U9-T02 | TICKET |
| U2-T01 | U9-T02 | TICKET |
| U2-T02 | U9-T02 | TICKET |
| U2-T03 | U9-T02 | TICKET |
| U2-T04 | U9-T02 | TICKET |
| U2-T05 | U9-T02 | TICKET |
| U3-T01 | U9-T02 | TICKET |
| U3-T02 | U9-T02 | TICKET |
| U3-T03 | U9-T02 | TICKET |
| U4-T01 | U9-T02 | TICKET |
| U4-T02 | U9-T02 | TICKET |
| U4-T03 | U9-T02 | TICKET |
| U5-T01 | U9-T02 | TICKET |
| U5-T02 | U9-T02 | TICKET |
| U5-T03 | U9-T02 | TICKET |
| U5-T04 | U9-T02 | TICKET |
| U6-T01 | U9-T02 | TICKET |
| U6-T02 | U9-T02 | TICKET |
| U6-T03 | U9-T02 | TICKET |
| U6-T04 | U9-T02 | TICKET |
| U6-T05 | U9-T02 | TICKET |
| U7-T01 | U9-T02 | TICKET |
| U7-T02 | U9-T02 | TICKET |
| U8 universal 500-line gate (U8 tickets, other agent) | U9-T02 | EXTERNAL |

## For the U8 tickets (other agent)

- `U0-T02` (refreshed owner ledger) and `U0-T03` (transitional gate) should precede the U8 tickets.
- U8 shared-path tickets wait for the owning U ticket that edits the same file (for example
  `decision_store.ex` after `U6-T01`/`U6-T02`; `issue_sync.ex` after `U2-T01`/`U2-T02`).
- The U8 universal-gate ticket precedes `U9-T02` (listed there as a text blocker).

Counts: 58 outbound, 75 inbound/internal.

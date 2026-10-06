# MP-R3 tickets

Base `45a290e3`, researched 2026-10-06. MP-R3 is a confirmation feature. It adds
test guards and docs, and changes no runtime behaviour (plan § 2). Phase C merged
the plan's four tickets into two. The two C1 test tickets touch the same test
files and are one small PR, and the optional banner became a conditional step of
the docs ticket.

| ID | Title | Status | Blocked by | Wave |
| --- | --- | --- | --- | --- |
| [MP-R3-C1-T01](MP-R3-C1-T01.md) | Authorization-independence guards: route and socket census, bind matrix, HTTP-only listener | blocked | DESIGN-R3 | 1 |
| [MP-R3-C2-T01](MP-R3-C2-T01.md) | Docs: reachability is not authorization; the dashboard is plain HTTP | blocked | DESIGN-R3 (incl. CR-R3-1 copy) | 1 |

**U0 gate (RC-19, X-58):** every MP-R3 ticket waits for U0 review of the prior plan
(`docs/plans/2026-09-29-001-refactor-production-readiness-plan.md`), because RC-19 keeps that
gate for refactor work. U0 has no ticket ID, so the gate is stated here and not in
`blocked_by`; the MP-R1-C11-T02 recheck does not replace it.

## Order and concurrency

- The two tickets are independent and may run concurrently. Neither depends on
  MP-R1. If MP-R1-C6 has split the router first, C1-T01 iterates every router.
- MP-R4-C1-T01 cites C1-T01's census. It can merge in either order, because it
  is docs only.
- RC-15 (RQ-TRANSPORT, owned by MP-N2) is supported here as follows:
  - the HTTP-only guard in C1-T01;
  - § Transport in C2-T01.

  Neither ticket chooses an HTTPS method.

## Phase C answers to the plan's questions

- **Route metadata key:** `Phoenix.Router.routes/1` (public) does not carry
  `pipe_through` (`deps/phoenix/lib/phoenix/router.ex:549-550`).
  `Phoenix.Router.route_info/4` (public) returns `:pipe_through` (`:1415`), and
  the census uses it.
- **`__sockets__/0`:** it exists but is `@doc false` (`endpoint.ex:692-693`).
  The census uses it with a comment, because Phoenix's own `ChannelTest` relies
  on it.
- **`/live` without a session:** it is accepted at `connect`
  (`phoenix_live_view/socket.ex:98-100`) and rejected at `on_mount`. The
  existing `financial_data_access_test.exs:112` asserts the `on_mount` contract.
- **Resolved-hostname bind case:** dropped. It needs DNS, and the literal-IP
  cases cover the guard decision.

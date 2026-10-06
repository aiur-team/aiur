# MP-R4 tickets

Base `45a290e3`, researched 2026-10-06. MP-R4 confirms that the
`hooks.aiur.dev` relay is an inbound, webhook-only tunnel. It adds no code.
Phase C merged the plan's two docs tickets into one PR, because they are two
paragraphs on two pages.

| ID | Title | Status | Blocked by | Wave |
| --- | --- | --- | --- | --- |
| [MP-R4-C1-T01](MP-R4-C1-T01.md) | Docs: the webhook ingress is replaceable and optional, and what its operator can see | blocked | DESIGN-R4; U8 DOCS size owner for `apis/github.md` | 1 |

- **MP-R4-C2** (the MP-Q2 fact-sheet hand-off) has **no implementation ticket**.
  The coordinator links plan § 4 from MP-N4 and `context-and-decisions.md`.
- **Concurrency:** C1-T01 may run with any other wave-1 ticket. It cites
  MP-R3-C1-T01's census but does not wait for it, because it is docs only.
- **Phase C research answered:**
  - **RQ1:** yes, Cloudflare terminates TLS at its edge and can read delivery
    bodies (edge-certificates doc, accessed 2026-10-06).
  - **RQ2:** the four `mode_test`s in `consumer_equivalence_test.exs` run
    against both transports. `:35` ("no transport marker") is the guard MP-R2
    must preserve.

# Aiur next-feature research

Research toward the next wave of Aiur/IR feature directions, kicked off from the operator's brief. Each doc follows the same shape: **landscape → concrete design → build-vs-adopt → risks → v1 cutline**, with inline citations.

## Documents

| Doc | Direction | Source pillars |
|---|---|---|
| [optimization-pillars-v2.md](./optimization-pillars-v2.md) | The originating brief (dashboard analytics + cloud execution) | all |
| [run-ledger-and-cost-analytics.md](./run-ledger-and-cost-analytics.md) | Durable metrics/cost substrate (Langfuse/Helicone/OTel-GenAI) | 1, 6 |
| [provider-usage-rate-limit-apis.md](./provider-usage-rate-limit-apis.md) | OpenAI/Anthropic usage/cost/rate-limit APIs + throttling | 6 |
| [cloud-containerized-execution.md](./cloud-containerized-execution.md) | Controller/worker; ECS-Fargate vs Batch/Cloud-Run/Fly/Modal/E2B | 7 |
| [multi-agent-messaging-and-roles.md](./multi-agent-messaging-and-roles.md) | Roles/workflows + typed inter-agent messaging (LangGraph/CrewAI/A2A) | 3, 4 |
| [durable-agent-memory.md](./durable-agent-memory.md) | Write-first memory; graph-vs-vector; "Omnigraph" verdict | 5, 8 |

## Cross-cutting findings (what every brief independently converged on)

1. **Build native, adopt vocabularies — not frameworks.** Across ledger, messaging, and memory, the recommendation is the same: Aiur already owns the orchestration loop, the event bus, and the call sites, so it should build thin native layers and only *borrow schema vocabulary* — OTel-GenAI attribute names for the ledger, the A2A message envelope shape for messaging — so future interop is a translation layer, not a rewrite. Importing LangGraph/CrewAI/A2A/MCP wholesale is premature.

2. **Postgres is the shared substrate.** Two independent briefs (run-ledger, memory) landed on the *same* store: Postgres via Ecto, with `pgvector` for fuzzy text and Apache-AGE / recursive-CTE / SQL-PGQ property-graph queries for relational depth. That means the run-ledger, cost analytics, and durable memory are **one database and one ingestion path**, not three services — a strong argument for the brief's "shared event spine." (This revises the brief's SQLite-first suggestion: prefer Postgres given the stated multi-controller trajectory, but keep a `RunLedger` behaviour so SQLite stays a valid local adapter.)

3. **The event bus is the single ingestion point.** A `:telemetry` handler on Aiur's existing event bus feeds the ledger; the same events project into memory; the same envelope carries agent-to-agent messages. Define one internal event vocabulary and adapt it outward (dashboard, memory, cloud, messaging).

4. **A real, Aiur-specific constraint surfaced:** because Aiur drives Codex/Claude through their **CLIs/app-servers** (not raw HTTP), the rich per-call rate-limit headers are **not accessible** — real-time throttling is text-event-based (`usageLimitExceeded`), and admin cost APIs are ~5-min-lagged reconciliation only. So the near-term scheduling win is formalizing Aiur's *current* manual "reroute to the other backend on a usage limit" policy into an automatic AIMD concurrency envelope keyed on those text events — not header-level throttling. _(This exact scenario played out live during the refactor run that spawned this research.)_

5. **Local-first, cloud-optional, capability-honest.** Cloud execution is an `Aiur.AgentRunner` behaviour with `Local`/`RemoteStub`/`ECSFargate` adapters; the local runner stays default; a controller-owned kill switch reroutes to the local pool. Cloud v1 = ECS/Fargate `RunTask` (controller owns queue/retry/ledger; per-task tags give cost attribution for free), proven on **one** ticket before scaling.

## Suggested build order (synthesized, not a commitment)

The briefs agree on a dependency order that matches the source brief's roadmap:

1. **`Aiur.RunLedger` on Postgres + telemetry ingestion** — the substrate everything else needs (cost, memory, routing).
2. **Dashboard analytics** (ticket cost/token/runtime) on top of the ledger.
3. **Rate-limit-aware scheduling** — AIMD envelope from text events now; admin-API reconciliation for the dashboard.
4. **Roles + typed messaging** — native, on the event bus, A2A-shaped envelope.
5. **Remote-worker boundary** — `AgentRunner` behaviour + Fargate spike on one ticket.
6. **Write-first memory** — a projection of the ledger into the same Postgres (pgvector + typed edges), retrieval gated behind an operator flag + corpus-size threshold.

_Status: research only. No implementation decisions committed — this branch exists to ground the next planning cycle._

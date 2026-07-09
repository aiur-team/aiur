# Run-Ledger / Cost-Analytics Substrate — Research Brief

_Part of the `research/optimization-pillars` wave. Maps to Pillar 1 (measurement/run-ledger substrate) and Pillar 6 (dashboard analytics)._

**Research value: high** — Substantial, convergent prior art across five mature observability platforms plus the OpenTelemetry GenAI spec, with concrete schema fields, storage-migration postmortems, and one directly-analogous small OSS project (agent-ledger).

## Landscape

| Tool | Event/schema unit | Cost attribution | Storage | Self-host |
|---|---|---|---|---|
| **Langfuse** | Trace → Observation (span/generation/event) → Score; Session groups traces; attributes (user_id, tags) cascade trace→observation | "Ingested cost prioritized over inferred cost"; inferred = tokens × regex-matched model-pricing catalog, with volume-tiered pricing | Postgres (metadata/txn) + ClickHouse (OLAP, ReplacingMergeTree for append-not-update) + Redis (queue/cache) + S3 (blobs) | MIT OSS; 1000+ self-hosted ClickHouse deployments as of Mar 2025 |
| **Helicone** | Proxy-captured request/response log | Static provider pricing tables; Anthropic needs a bespoke Python tokenizer service (no reliable TS tokenizer) | Proxy layer, <5ms p95 added | OSS cost calculator (300+ models) |
| **LangSmith** | Run tree with `usage_metadata`/`cost_details` | Three-way token typing: input (incl. `cache_read`), output (incl. `reasoning`); per-type $ config | Commercial SaaS, LangChain-native |
| **Arize Phoenix / OpenInference** | Span, `llm.token_count.{prompt,completion,total}` + `.prompt_details.{cache_read,cache_write}` | Cost derived only if token counts present in span; no vendor reconciliation | OTel-based, Apache-2.0 |
| **Braintrust (Brainstore)** | Trace/span, spans routinely >1MB | (cost model not deeply documented) | Postgres = pointers/metadata only; object storage (S3/GCS) WAL + custom Rust streaming engine, built because generic OLAP/relational stores couldn't handle arbitrary-field queries + late child-span writes | Control-plane/data-plane split |
| **OTel GenAI semconv** | Span `gen_ai.*` attrs: `usage.input_tokens`, `usage.output_tokens`, `usage.cache_creation.input_tokens`, `usage.cache_read.input_tokens`, `usage.reasoning.output_tokens`, `operation.name`, `agent.id/name`, `provider.name`, `tool.call.id/arguments` | **Not standardized** — no `gen_ai.cost.*` in spec | Wire format only, not a backend | Status: "Development," several attrs already Deprecated as of May 2026 |

**What to borrow:** Langfuse's ingested-beats-inferred priority rule and regex-versioned pricing catalog; LangSmith's input/output token typing (cleanest match to actual provider response shapes); OpenInference's minimal viable attribute floor; Braintrust's cautionary tale — don't over-build storage for scale you don't have.

## Recommended event schema

```
runs      id, ticket_id, workflow, role, backend("codex"|"claude"), model,
          started_at, ended_at, outcome, routing_reason

turns     id, run_id, turn_index, started_at, ended_at, status,
          provider_request_id   -- vendor's own id, enables later reconciliation

usage     turn_id, input_tokens, cache_read_input_tokens, cache_write_input_tokens,
          output_tokens, reasoning_output_tokens, total_tokens

cost      turn_id, amount_usd, pricing_model_id,
          confidence("estimated"|"reconciled"), source("token_catalog"|"provider_field"|"billing_api")

pricing_catalog  provider, model_pattern(regex), effective_from,
                 input_usd_per_mtok, output_usd_per_mtok,
                 cache_read_usd_per_mtok, cache_write_usd_per_mtok, reasoning_usd_per_mtok
```

Denormalize `ticket_id`/`role`/`routing_reason` onto `turns` (Langfuse's attribute-propagation pattern) so dashboard queries avoid joins. Field names deliberately mirror `gen_ai.*` vocabulary for future OTel interop without a schema rewrite.

## Storage recommendation

**Postgres via Ecto, not SQLite, not ClickHouse yet.** SQLite's single-writer lock fights Aiur's stated trajectory to multi-controller; the Elixir community's own migration path off SQLite is a costly "dual-write then cut over" exercise. Postgres handles Aiur's actual scale (10s of agents, thousands of runs) trivially — the OLAP pain Langfuse/Braintrust hit only appears at "millions of rows, enterprise ingestion volume," an order of magnitude beyond Aiur. Attach a `:telemetry` handler to the existing internal event bus as the ingestion trigger (mirrors Ecto's own `[:my_app, :repo, :query]` event pattern) rather than standing up a separate service. Revisit ClickHouse only if dashboard aggregates need sub-second queries over millions of turn rows.

> _Note vs. the source brief:_ the original `optimization-pillars-v2.md` suggested **SQLite for local-first v1**. This research argues Postgres-from-the-start is the safer bet given the stated multi-controller/cloud trajectory (SQLite→Postgres migration is the expensive part). A pragmatic middle: keep the `Aiur.RunLedger` behaviour so SQLite and Postgres are both adapters, and default to whichever matches the deployment — but do **not** design the schema around SQLite-only assumptions.

## Cost-attribution model

No tool in this scan exposes a formal confidence tier to users — this is a synthesis. Recommend three explicit tiers:
1. **Estimated** — provider-returned token counts × `pricing_catalog`. What every scanned tool does by default.
2. **Reconciled** — provider's own billed-cost figure overriding the catalog computation (Langfuse's "ingested cost" path). Note: neither OpenAI nor Anthropic returns a per-call dollar figure today, so true reconciliation requires an out-of-band billing-API pull matched by `provider_request_id` — no tool automates this end-to-end; treat as periodic batch reconciliation, not real-time. _(Corroborated by the provider-usage brief: Admin cost APIs lag ~5 min and are daily-bucketed.)_
3. **Allocated** — cross-ticket/role/workflow rollups (FinOps "allocation" capability); a dashboard-layer concern, not a raw-ledger concern.

v1 needs only tier 1, plus the `provider_request_id`/`confidence`/`source` fields so tiers 2–3 are additive later without migration.

## Build vs adopt

**Build a native `Aiur.RunLedger`.** Every mature external tool reinvents a bespoke storage/query engine (ClickHouse, Brainstore) to serve a generic "trace from any app" model — disproportionate for Aiur's already-typed, small-scale entity model. Aiur controls both SDK call sites directly, so it reads exact usage fields instead of guessing via network interception (Helicone's own docs admit this is unreliable for Anthropic). Adopt OTel GenAI attribute *names* internally at zero cost, keeping a future path open to also emit real OTLP spans (feeding Langfuse/Tempo).

## Risks

- OTel GenAI semconv attributes are actively being renamed/deprecated mid-spec — treat as vocabulary inspiration, not a contract.
- Cost is entirely absent from the OTel spec — the pricing catalog is 100% custom-build regardless, and needs ongoing maintenance as provider pricing shifts.
- Tokenizer drift: reports of newer Anthropic tokenizers producing up to ~35% more tokens for identical text — a static catalog silently mis-prices new model versions without effective-dated regex patterns.
- Reasoning tokens are billed at output rate but not broken out by OpenAI as a separate cost line — must capture `reasoning_output_tokens` explicitly or lose cost transparency on reasoning-heavy Codex runs.
- Storage-tier decisions are costly to reverse live (documented dual-write cutover pattern) — decide now, not later.

## v1 cutline

**Ship:** `runs`/`turns`/`usage`/`cost` tables in Postgres/Ecto; telemetry-handler ingestion off the existing event bus; estimated-tier cost only; OTel-vocabulary field names; `provider_request_id` captured for future use.
**Defer:** real OTLP emission, external-tool integration, reconciled/allocated cost tiers, ClickHouse, proxy-based capture.

## Sources
- [Langfuse Data Model](https://langfuse.com/docs/observability/data-model)
- [Langfuse Token & Cost Tracking](https://langfuse.com/docs/observability/features/token-and-cost-tracking)
- [Langfuse v3 Infrastructure Evolution](https://langfuse.com/blog/2024-12-langfuse-v3-infrastructure-evolution)
- [Helicone: How We Calculate Cost](https://docs.helicone.ai/references/how-we-calculate-cost)
- [OpenTelemetry GenAI Attributes Registry](https://opentelemetry.io/docs/specs/semconv/registry/attributes/gen-ai/)
- [OpenInference Semantic Conventions](https://arize-ai.github.io/openinference/spec/semantic_conventions.html)
- [Braintrust Brainstore Architecture](https://www.braintrust.dev/blog/brainstore-architecture)
- [GitHub: WDZ-Dev/agent-ledger](https://github.com/WDZ-Dev/agent-ledger)
- [LangSmith Cost Tracking Docs](https://docs.langchain.com/langsmith/cost-tracking)
- [Fly.io: SQLite3 for Elixir](https://fly.io/docs/elixir/advanced-guides/sqlite3/)
- [FinOps Allocation Framework Capability](https://www.finops.org/framework/capabilities/allocation/)

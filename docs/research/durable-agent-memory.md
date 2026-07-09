# Durable Memory for Coding Agents — Research Brief

_Part of the `research/optimization-pillars` wave. Maps to Pillar 5 (durable memory with Omnigraph) and Roadmap Phases 7–8 (write-first memory sink + retrieval/routing)._

**Research value: high** — direct architectural prior art exists (PROJECTMEM), multiple mature comparables are well-documented (Mem0, Zep/Graphiti, Cognee, LangMem), and 2026 practitioner consensus on graph-vs-vector for dev memory is concrete and convergent rather than contested.

## 1. Memory-systems comparison table

| System | Memory model | Storage | Extraction pipeline | Retrieval | Provenance/decay | Self-host |
|---|---|---|---|---|---|---|
| **Mem0** | Episodic+semantic, 3-tier (user/session/agent) | Hybrid: vector+graph+KV | LLM extracts memories from recent turns → separate LLM "update" pass tool-calls add/update/delete/no-op vs most-similar existing | `search()` top-k by scope | Update-history only; no first-class confidence; graph variant "Mem0g" | Yes, OSS (Apache-2.0) + hosted |
| **Zep / Graphiti** | Temporal knowledge graph | Graph (Neo4j/FalkorDB) + edge/node embeddings | Incremental, non-batch entity/edge extraction per new episode | Vector entry-point → graph traversal | Bi-temporal edges (`t_valid`/`t_invalid`) — built-in provenance; superseded facts marked invalid, never deleted | Graphiti OSS on Neo4j/FalkorDB; Zep hosted |
| **Letta (MemGPT)** | OS-style paging: in-context "core" blocks + out-of-context "archival" | Vector archival + editable blocks | Agent decides via function calls what to page (no extractor) | Agent-invoked memory tools | Every block edit agent-visible/diffable; no built-in confidence | Yes, OSS + hosted |
| **Cognee** | Data + ontology-grounded graph + vector | 3-tier: relational (provenance) + vector + graph | "cognify" (classify→chunk→extract→summarize→embed); "memify" prunes/reweights | Vector, graph traversal, hybrid, multi-hop | Relational store carries provenance; memify reweights edges by usage | Yes, OSS (Apache-2.0) |
| **LangMem** | Semantic+episodic+procedural | Pluggable via LangGraph `Store` (vector/KV/Postgres) | Memory Manager LLM pass decides store/update/delete | Namespaced similarity search | Namespace isolation only; no confidence field | Yes, OSS, backend-agnostic |
| **PROJECTMEM** (closest analog) | Event log (issue/attempt/fix/decision/note) → deterministic projections | Plain-text append-only JSONL, no DB | **None** — structured writes via CLI/MCP tool calls, no free-text mining | 15 MCP tools; token-budgeted `get_context()`; `precheck_file()` pre-commit gate | Git-history cross-check flags stale citations (never auto-deletes); supersession preserved | Fully local stdio MCP subprocess |

Reported numbers (comparison blogs, directional): Zep/Graphiti 63.8% vs Mem0 49.0% on LongMemEval (GPT-4o); Zep's paper claims up to 18.5% accuracy gain, 90% latency reduction vs baseline.

## 2. Graph-vs-vector recommendation for dev memory

By 2026 the community has largely converged on **hybrid**: vector for semantic entry-point retrieval, graph for multi-hop relational depth. Microsoft's GraphRAG shows +26% comprehensiveness / +57% diversity over plain vector RAG on relationship-heavy queries — and the structurally relevant case here is "this fix touched file X, imported by Y, which broke test Z," which is graph-shaped, not similarity-shaped.

The dev-memory-specific argument for graph: near-identical *surface* symptoms can have different root causes (SQLite-lock vs stale-migration; wrong venv vs wrong PYTHONPATH) — a flat vector index returns both as neighbors with no disambiguation, whereas typed edges (`failure -[caused_by]-> root_cause`, `fix -[resolves]-> failure`, `fix -[touches]-> file`) let retrieval walk the actually-relevant chain.

**Key leverage point for Aiur**: Cognee/Graphiti's LLM-based entity/relation extraction is expensive and lossy. **Aiur's run-ledger already emits structured events** — the hardest part of graph construction (extracting entities/relations from free text) is sidestepped entirely. This is PROJECTMEM's core insight: write structured relations at the point of origin, don't mine transcripts after the fact.

**Recommendation**: model the graph as typed-edge tables inside the existing Postgres run-ledger (via Apache AGE, recursive CTEs, or the emerging SQL/PGQ standard), plus a pgvector column over failure/fix free-text for the fuzzy "similar-but-not-identical" case. One storage engine, no new service.

## 3. Write-first schema (concrete)

Append-only, immutable event types (mirrors PROJECTMEM, adapted to a run-ledger):

```
failure    {id, ticket_id, run_id, agent, timestamp, symptom_text,
            file_paths[], test_name?, error_class, git_sha}
attempt    {id, failure_id, approach_text, outcome: failed|partial|worked, diff_ref?, timestamp}
fix        {id, failure_id, closes_attempt_id, diff_ref, file_paths[], test_name?, pr_number, confidence}
decision   {id, scope, statement, supersedes_id?, timestamp, author_agent}
flaky_test {id, test_name, run_ids[], first_seen, last_seen, resolution_status}
pr_outcome {id, pr_number, merged|reverted|abandoned, revert_of?, timestamp}
```

Every record carries provenance: `source_run_id`, `source_agent` (codex/claude), `git_sha_at_write`, `confidence`, `superseded_by`.

**Confidence is deterministic, not LLM-judged**: a fix stays "provisional" until (a) N later runs hit the same failure signature and the same fix resolves it, or (b) M days pass with no revert/regression on touched files. Avoids the self-trust attack surface (§6) and matches PROJECTMEM's deterministic-projection philosophy.

**Staleness check**: before surfacing a `fix`/`decision`, diff the cited file's git history against `git_sha_at_write`; if commits exist since, mark `possibly_stale` — flag, never silently serve, never auto-delete.

> _Aiur note:_ this schema is essentially the refactor loop's own hard-won learnings made durable — flaky-test signatures, "v2-merges don't auto-close," the `model:claude`→gpt-5.5 bug, merge-order thrash. Aiur already writes many of these as `emit_alert`/log events; the memory layer is a projection of the run-ledger, not a new capture path.

## 4. Retrieval design + guardrails

- **Narrow the query shape**: retrieval only answers "have we seen this failure signature before" (error_class + file_path + test_name match), not general free-text recall. Bounds the poisoning/staleness surface.
- **Abstention-first**: default to *not* injecting; only surface a prior fix if (signature similarity clears threshold) AND (confidence = "promoted") AND (not `possibly_stale`). Penalize false positives (wrong memory injected) harder than false negatives.
- **Bounded, provenance-tagged injection**: token-budgeted block, each entry inline-tagged (`[from PR #123, confirmed 2026-05-02, 4 confirmations]`) so agent and reviewer see it's a suggestion, not ground truth.
- **Operator kill switch**: retrieval-into-prompts independently disableable from the write path — write-first is unconditional, retrieval is not.
- **Corpus-size gate**: don't wire retrieval into prompts until enough repeat-signature hits exist (e.g., ≥20–30 promoted fixes with ≥2 recurrences).

## 5. "Omnigraph" verdict

**Naming collision is real**: at least six unrelated projects use "Omnigraph," two directly in-lane ([`ModernRelay/omnigraph`](https://github.com/ModernRelay/omnigraph) — "lakehouse native graph engine" for multi-agent coordination; [`chandrahmuki/OmniGraph`](https://github.com/chandrahmuki/OmniGraph) — "knowledge graph CLI... scans code, docs, and memory"), plus NVIDIA's established Omniverse "OmniGraph" brand. **Treat "Omnigraph" as an internal codename only.**

**Framing verdict**: "dev/knowledge graph" undersells the vector-similarity half (fuzzy "seen something like this" queries won't hit exact typed-edge matches). Every mature comparable converges on **hybrid**, not graph-only — frame it as a hybrid store.

**Build-vs-adopt**: none of Mem0/Zep/Letta/Cognee/LangMem are drop-in (Python-first, service-shaped, or require Neo4j/FalkorDB; none integrate with an Elixir/Postgres run-ledger). PROJECTMEM is the closest architectural analog (event log → deterministic projections → on-demand retrieval, local-first, no LLM-mining) — read it as a reference architecture, not a dependency.

**Pragmatic call**: no separate graph DB for v1. Use Postgres (existing run-ledger) + pgvector + Apache AGE or recursive-CTE property-graph queries (SQL/PGQ is landing natively in Postgres). Graph = one Postgres schema, not a new service.

## 6. Risks

- **Memory poisoning**: agents trust their own memory more than fresh input — a bad fix logged with high confidence biases future agents. Mitigate: provenance on every write; confidence promoted only by deterministic outcome signals (never LLM self-assessment); PR-merge checkpoint before a `decision` supersedes another.
- **Sleeper/delayed poisoning**: wrong content stored now, retrieved later after original context is gone. Mitigate by requiring PR-merge (not just CI-green) before a fix promotes past provisional.
- **Drift/staleness**: PROJECTMEM's git-cross-check is the concrete, cheap mechanic to borrow — flag, never silently trust, never auto-delete.
- **Retrieval-induced harm**: near-identical-symptom/different-root-cause failures — signature matching on symptom text alone misfires; schema needs structured fields (error_class, file_path, test_name, git_sha).
- **Cost/complexity creep**: resist adding an LLM-mining/extraction step until the structured-write path is proven insufficient — that's the expensive path Cognee/Graphiti take that Aiur can skip.

## 7. v1 cutline

**In**: structured event schema written directly from the run-ledger (no LLM extraction); Postgres storage reusing the existing DB (pgvector for fuzzy text, typed-edge tables/AGE for structure); deterministic confidence promotion; git-cross-check staleness flag; on-demand read API ("have we seen this?") with **no automatic prompt injection**.
**Deferred**: always-on prompt injection (gate behind operator flag + corpus-size threshold); LLM-based extraction from transcripts; a standalone graph DB service; cross-repo memory inheritance; any trust model driven by agent self-assessment.

## Sources
- [PROJECTMEM (arXiv:2606.12329)](https://arxiv.org/abs/2606.12329) & [riponcm/projectmem](https://github.com/riponcm/projectmem) — closest architectural analog
- [Zep: Temporal Knowledge Graph for Agent Memory (arXiv:2501.13956)](https://arxiv.org/abs/2501.13956) & [getzep/graphiti](https://github.com/getzep/graphiti)
- [Cognee core concepts](https://docs.cognee.ai/core-concepts/overview) & [topoteretes/cognee](https://github.com/topoteretes/cognee)
- [Mem0 (arXiv:2504.19413)](https://arxiv.org/pdf/2504.19413) · [LangMem SDK launch](https://www.langchain.com/blog/langmem-sdk-launch)
- [Memory Poisoning Attack/Defense (arXiv:2601.05504)](https://arxiv.org/pdf/2601.05504) · [Abstention-Aware Memory Retrieval (arXiv:2604.27283)](https://arxiv.org/pdf/2604.27283)
- [GraphRAG vs Vector RAG](https://www.singlestore.com/blog/rethinking-rag-how-graphrag-improves-multi-hop-reasoning-/) · [SQL/PGQ in Postgres](https://pgweekly.github.io/en/2026/07/sql-property-graph-queries-pgq.html)
- [ModernRelay/omnigraph](https://github.com/ModernRelay/omnigraph) · [chandrahmuki/OmniGraph](https://github.com/chandrahmuki/OmniGraph) — naming-collision evidence

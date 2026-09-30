# Lower-fanout inline literal checkpoint

Frozen source: `3339b887196d5e9aefb273117a14bf33391ee41f`.
The full parse-only census (decompressed SHA256
`8312b5b6289193bedc1c0c439a5238833e0e3baf9a50aff469e7fde8b5a826e8`)
contains 9,827 distinct scalar values. Of these, 1,705 appear in at least two
modules: 880 strings of at least eight characters, 112 numbers other than
zero/one, and 713 shorter strings or zero/one values. The 191 selected
high-fanout groups are a subset, not a separate population. This checkpoint
inspects the following lower-fanout source-role candidates; it does not
declare the other 1,514 groups semantically cleared.

| Value | Frozen source and role | Disposition |
| --- | --- | --- |
| `64_000` | `build_order/member.ex:93-94` validates `draft_body` at record construction; `aiur_web/build_order/planning_source.ex:807-816` bounds the document read that produces it. | Same draft-body byte contract at two boundaries; provisional `dup-by-constant-03`. Keep path-containment and record validation distinct. |
| `-32_003` | `agent_runner/checkpoint_delivery.ex:154-163` and `agent_runner/queue_drain.ex:743-748` recognize provider active-turn rejection, restoring durable work through different APIs. | Shared protocol error identity; provisional `dup-by-constant-04`. Different outer tuples and restoration transitions remain separate. The AST scalar census stores the unsigned leaf `32_003` beneath unary minus, so source context is required. |
| `openai-compatible-2026-08` | `usage/headless/{deep_seek,kimi,open_router}/request_usage.ex:15` and `usage/headless/open_ai_compat/request_usage.ex:12` repeat the source version. | Already covered by `telemetry-usage-32` as part of near-identical adapters; no new finding. |
| `65_536` | `config/schema/opencode.ex:22` and `opencode/config.ex:72,81` validate the same bridge port range at YAML/env and runtime boundaries. | Common port protocol bound, but entry paths and error behavior differ. A shared literal alone adds little beyond the existing schema; do not merge validation paths. |
| `PRAGMA busy_timeout = ` | `asks_store.ex:19` sets an exclusive-store lock timeout, `github/budget_ledger.ex:111` configures a read-only snapshot, and `opencode/db.ex:193` controls opencode writes. | Shared SQLite syntax, distinct timeout values and failure contracts. Reject one global timeout constant. |
| `cache_read_input_tokens` | `usage/headless/claude/request_usage.ex:102`, `usage/headless/codex/tokens.ex:59`, and `usage/headless/open_ai_compat/request_usage.ex:90` admit the same input alias with different provider provenance and fallback order. | Wire-key equality belongs in provider adapter contracts; existing telemetry/usage review owns the broader relationship. Do not flatten precedence. |

The source inspection is bounded to these candidates and the high-fanout
shape screen. Dynamic strings, macros, generated code, non-Elixir code and
all unreviewed lower-fanout groups remain outside a completed constant unit.
No runtime frequency or LOC saving is inferred.

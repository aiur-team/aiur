# Inline literal review checkpoint

Frozen revision: `3339b887196d5e9aefb273117a14bf33391ee41f`.

The parse-only `tooling/inline_literal_census.exs` covers all 1,032 frozen
`src/lib` Elixir files. It found 32,745 inline scalar AST leaves: 22,929
strings and 9,816 numbers. File hashes exactly match the existing function
census. The first implementation accidentally traversed token metadata and
counted source line/column integers; the corrected traversal and synthetic
fixture reject that false population. The full output is private at
`scratch/inline-literal-census.json.gz`; its decompressed SHA256 is
`8312b5b6289193bedc1c0c439a5238833e0e3baf9a50aff469e7fde8b5a826e8`.
It contains source literals, no runtime values.

`tooling/inline_literal_summary.py` selects high-fanout values: static strings
with at least eight characters and five distinct modules, and nonzero,
nonone numbers in five distinct modules. The tracked
`inline-literal-summary.json` preserves 191 values, three source anchors per
value, occurrence counts, and lexical routing shapes: 142 strings and 49
numbers. Selection is a review threshold, not a claim that a two-site shared
policy cannot matter. The complete lower-fanout population remains available
in the private census, and named attributes and regex sigils have separate
full candidate assessments.

## Source-role assessment

| Shape | Groups | Assessment |
| --- | ---: | --- |
| Field or identifier token | 74 | Repeated wire keys (`created_at`, `schema_version`, `decision_id`, `observed_at`) belong to their record schemas. An identical key is not permission to merge persisted schemas or treat missing and null identically. Related `input_tokens`/`output_tokens` belong to provider adapters and usage envelopes with different provenance. |
| Bound, duration, size or protocol number | 25 | Mixed units and owners. `100` occurs in progress percentages as well as counts; `5_000`, `15_000` and `30_000` govern unrelated call, cache and refresh deadlines; `512` is both a membership run-ID bound and unrelated text/path limits. Share a number only with its named contract. |
| State or display enum | 17 | Labels such as `human-review`, `cancelled`, `completed` and `unavailable` cross tracker, runtime and UI layers. The label/state concept ledger requires typed boundaries and explicit unknown handling. |
| Display or log fragment | 17 | Fragments such as ` reason=` and ` issue_identifier=` compose different messages. Preserve redaction, field identity and unavailable wording at each renderer; string equality alone is no extraction. |
| Protocol path, header or environment name | 14 | `application/json`, `x-ratelimit-*`, `GITHUB_TOKEN`, `AIUR_*`, URLs and repository refs are protocol constants. The GitHub API guide governs request accounting; a common lexical value does not merge credential or endpoint ownership. |
| Topic or event fragment | 13 | `.pr.merged`, `.issue.commented`, `turn/completed` and `executor.` are parts of different topic grammars. See the concept draft and the inherited topic findings; parsing and ticket identity need source-aware contracts. |
| Small ordinal or count | 12 | Values 2–16 appear as indices, counts, versions and retry bounds. No shared constant follows from the integer alone. |
| HTTP status candidate | 7 | `200`, `299`, `304`, `401`, `403`, `404`, `429` express HTTP protocol cases in different clients/controllers. Preserve the endpoint's response and retry contracts. |
| Other literal shape | 7 | Composite fragments and symbols need their enclosing expression; they are retained in the summary rather than promoted from a lexical match. |
| Time-unit candidate | 4 | `1_000`, `3_600`, `60_000`, `86_400` appear in conversion and policy expressions. Conversion math may be shared, but freshness, reset time, retention and UX thresholds remain distinct. |
| Private-file mode | 1 | Elixir parses `0o600` as 384. Repeated durable-store writes set private mode; preserve this requirement and use the existing filesystem owner, without treating every store's durability semantics as the same. |

The attribute/regex sweep's two strongest constant extraction candidates are
the four ordered five-token-dimension lists and the model probe/refresh timeout
relationship in `dup-by-constant-draft.json`. The lower-fanout follow-up adds
the Build Order draft-body bound and active-turn provider error code, with
source-role checks in `inline-literal-lowfanout.md`. Two other inline families corroborate other units:
the exact 1..512 membership run-ID check belongs with `dup-by-name-04`, and
progress percentage bounds belong with `dup-by-name-05`. They are not four
independent LOC savings.

## Limits and reproduction

The inline census excludes module-attribute declarations, quoted generated
code, macro expansions, dynamic strings and non-Elixir files. A literal inside
an interpolation is a fragment, and nearest enclosing AST metadata can give
an approximate line for list elements. The high-fanout summary is a candidate
selection; its shape labels are lexical, not independent source-consumer
verdicts. Lower-fanout inline literals are not semantically cleared by this
checkpoint. No running daemon, GitHub request, current-price check, cost
measurement or production file was touched.

Reproduce from the research branch with Elixir 1.19.5 / OTP 28:

```sh
python tooling/test_inline_literal_census.py
elixir tooling/inline_literal_census.exs /path/to/frozen-snapshot > /tmp/inline-literal-census.json
python tooling/inline_literal_summary.py /tmp/inline-literal-census.json
```

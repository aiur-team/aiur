# Static constant candidate closure

Frozen source: `3339b887196d5e9aefb273117a14bf33391ee41f`.
This closes a **bounded static candidate screen**, not every semantic use of a
literal. The attribute census assessed all 162 cross-module expression groups,
and the regex census assessed all 28 cross-module sigil groups. The inline
census parsed all 1,032 library Elixir files and recorded 32,745 scalar leaves
with checked source hashes. Its 1,705 cross-module typed values divide into
191 high-fanout role screens and 1,514 lower-fanout groups. The lower-fanout
work recorded source context for 316 long strings and 63 nontrivial numbers;
709 short strings have a role ledger. `inline-literal-role-closure.json`
routes the remaining 422 long and 448 short lexical matches through explicit
source roles. Four zero/one numeric forms are language primitives and carry no
standalone extraction proposal. Every static group has an indexed disposition
or source-role route; none is counted as a LOC saving by spelling alone.

| Remaining role route | Groups | Source-level judgment |
| --- | ---: | --- |
| Record/wire fields and common words | 576 | A repeated key needs its typed schema owner and missing/null policy. `"state"` names different fields in `analytics_cli.ex:263` and `build_gate.ex:293`; `"accepted_at"` belongs to decision lifecycle projections. The word itself is not an implementation to extract. |
| Identity fields | 12 | Keys such as `boot_id`, `turn_id` and `wake_id` require their record and persistence boundary; sharing only the spelling would not share validation. |
| Display/log fragments | 101 | `" remaining"` is operator text in CLI and run-summary presentation; preserve unit, freshness and unknown handling in each renderer. |
| Protocol, command or mechanic fragments | 116 | Git flags (`--git-dir`, `--others`) are external syntax; HTML entities and `<aiur:events>` are shared formatting protocols. The latter has separate delivery callers in CheckpointDelivery and QueueDrain; broader runtime findings retain those IDs. Equal fragments can point to an existing primitive, but do not justify merging failure policy. |
| Paths, headers and environment names | 22 | `AIUR_BG_STATE_DIR` is read by two configuration paths; `/v1/logs` connects telemetry sender and receiver. These are producer/consumer contracts, not duplicate implementations. GitHub endpoint paths retain distinct pagination and rate-accounting owners. |
| Topic fragments | 19 | `.agent.blocked` connects subscription and digest, while `phase:` connects Build Order metadata parsing and planning emission. `pr:` also names unrelated event-key and telemetry-ID namespaces. The typed event/topic concept unit owns grammar; no global string constant follows. |
| Status vocabulary | 23 | `OPEN` is an Asks display state and a Build Order lifecycle input; `pending` and `failed` cross unrelated state machines. The label/state concept unit preserves typed owners. |
| External syntax | 1 | The remaining symbol is syntax, not a standalone Aiur policy. |
| **Total** | **870** | Source-role route only; no blanket semantic-equivalence claim. |

The source-backed material proposals remain `dup-by-constant-01` through `05`
in the draft/raw unit: ordered token dimensions, nested model-probe budget,
Build Order draft-body cap, provider active-turn code and advertised dashboard
host. Existing `telemetry-usage-34`, `agent-runtime-09` and `web-occ-18`
retain their primary IDs where the same contract is already reported.
`inline-literal-long-tail.md` and `short-string-source-review.md` record
additional source checks and rejected lexical matches.
`constant-semantic-followup.md` checks risk-bearing routes against frozen
callers and inherited finding IDs; it found no sixth independent proposal.

The role routes are conservative **selection decisions**, not proof that all
callers implement equivalent behavior. Dynamic Regex.compile values, macro
expansion, generated code, non-Elixir literals, complete transitive call paths
and arbitrary differently named semantic duplication are outside the static
detector. Final cross-unit synthesis may merge or reject provisional IDs.

Reproduce the role ledger with:

```sh
python tooling/final_constant_triage.py \
  review/in-progress/inline-literal-lowfanout-ledger.json \
  review/in-progress/short-string-source-screen.json \
  > review/in-progress/inline-literal-role-closure.json
```

# Lower-fanout inline literal source-role pass

Frozen revision: `3339b887196d5e9aefb273117a14bf33391ee41f`.
Reproducer: `tooling/inline_literal_lowfanout_ledger.py`. The compact
`inline-literal-lowfanout-ledger.json` records all **1,514** typed values
excluded from the 191 high-fanout rows. Its path table and two distinct-module
line anchors are navigational; module and site counts cover every occurrence.
The source-line context codes and one-owner flag are machine routing hints,
not semantic verdicts. Numeric type is part of identity: `0` and `0.0`
remain separate. The census SHA is checked before ledger generation.

## Explicit selection boundary

| Population | Groups | Source-context screen | Left semantically unreviewed |
| --- | ---: | ---: | ---: |
| Long strings (at least eight characters) | 738 | 316 | 422 |
| Short strings | 709 | 0 here; delegated to separate short-string review | 709 in this artifact |
| Numbers | 67 | 63 nontrivial values, including `100.0` | 4 generic `0`, `1`, `0.0`, `1.0` |
| **Total** | **1,514** | **379** | **1,135** |

For long strings, the source-context screen includes **every value in four or
more modules** (73), **every value confined to one source-owner subtree in
two or three modules** (27), and **every remaining cross-owner value in two or
three modules whose spelling matches version, timeout, limit, status, topic,
auth, cache, quota, path, token, credential, session, rate, poll, retry,
webhook, workspace, issue, ticket, GitHub, Executor or Decision signals**
(127). Those disjoint sets total 227. For each, the first two distinct-module
source lines were inspected and all module source contexts/owner groups were
recorded. A further 89 homogeneous source clusters were screened: 72
web/presenter uses, 10 log-only fragments, four command strings, and three
event-topic strings. These are source-role screens rather than semantic
clearance. The remaining **422** long strings have mixed or opaque source
contexts and stay explicitly unresolved.

## Source-backed dispositions

- The same close-event syntax `^[a-z][a-z0-9-]{0,63}$` occurs in
  `conversation_drawer.ex:271` and `ticket_context.ex:318`; inherited
  `web-occ-18` already covers the helper pair. No additive finding.
- `64_000` bounds a Build Order draft body at `build_order/member.ex:93` and
  `aiur_web/build_order/planning_source.ex:814`; `-32_003` recognizes the
  provider active-turn error in `agent_runner/checkpoint_delivery.ex:161`
  and `agent_runner/queue_drain.ex:743`. These remain provisional
  `dup-by-constant-03` and `dup-by-constant-04`; the AST records `32_003`
  beneath unary minus.
- `59_999` is the same minute-ceiling expression in
  `orchestrator/issue_sync.ex:2274` and `orchestrator/status_reason.ex:71`.
  `65_000` is the pane open/attach `GenServer.call` timeout across
  `agent_list/activation.ex:107` and `pane_manager.ex:78,124`. Both are
  source-backed candidates for an owner-level contract, without a measured
  saving.
- `127.0.0.1` appears in seven modules. Config defaults, listener bind
  fallback, UI display and allowed-origin checks use the same loopback host
  under different contracts (`config/schema/opencode.ex:10`,
  `http_server.ex:260,264`, `aiur_web/router.ex:356,362`). A global string
  constant would obscure those roles.
- `rate_limit` spans Claude provider payloads and GitHub endpoint names
  (`claude/rate_limit_adapter.ex:48`, `github/endpoint_policy.ex:52`);
  `unlimited` spans Codex credit metadata and a config input spelling
  (`codex/rate_limit_adapter.ex:292`, `config/schema/agent.ex:474`). These
  are lexical false matches, not shared policies.
- The two GitHub ticket-attribution readers use the same path regex
  `/(?:issues|pulls)/(\d+)(?:/|$)` (`github/quota.ex:1256`,
  `github/request_log.ex:284`) and the same `number issue_number pull_number`
  alias list (`github/quota.ex:1276`, `github/request_log.ex:303`). The
  inherited GitHub attribution review owns this cross-module relationship.
- `session:` is produced as an opaque live conversation ID and validated by
  orchestrator state (`live_conversation/source.ex:80`,
  `orchestrator/state.ex:675`). This is a producer/consumer format contract;
  a shared string alone does not make their validation and generation one
  function.
- Shared CLI/UI wording such as `has not polled yet`, `ticket supply`,
  `agent unavailable` and `tracker unavailable` is duplicated across
  presenters. Those are consistency candidates, but the caller still owns
  the unavailable cause and age. The event and topic fragments are already
  represented by the concept/event units.

The 63 numeric source-line screens classify parser/character codepoints,
HTTP and system protocol numbers, same-contract candidates, shared mechanics
with separate owners, and unrelated units. In particular, AST leaves such as
`115` can arise from a regex modifier, and `97` can arise from a sigil or
character syntax; decimal matching without source inspection is unsound.
The compact ledger retains each value and anchors so a later review can
close the exact 1,135 unreviewed groups in this artifact. No runtime frequency, LOC saving,
or production change is claimed.

Reproduce from the research tree and frozen snapshot:

```sh
python tooling/inline_literal_lowfanout_ledger.py \
  /path/to/inline-literal-census.json.gz \
  review/in-progress/inline-literal-summary.json \
  /path/to/snapshot-3339b887-complete \
  > review/in-progress/inline-literal-lowfanout-ledger.json
```

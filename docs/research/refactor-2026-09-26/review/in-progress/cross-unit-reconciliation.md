# Cross-unit finding reconciliation

The frozen 32-unit corpus has 1,033 source IDs. The synthesis maps them to
986 planning items through 30 conservative semantic merges involving 77 IDs.
`review/findings.json` embeds every raw claim unchanged. The merge owner,
source IDs and reason are encoded in `tooling/review_synthesis.py`; the
independent `tooling/audit_review_synthesis.py` checks exact source-ID and
claim equality after rendering.

The [candidate index](cross-unit-candidates.json) applies a reproducible
lexical screen to all 1,033 raw entries: a pair must cite at least one common
path and score at least 0.35 by TF-IDF cosine over its title and first 500
description characters. It surfaced 25 pairs: 20 now share a canonical work
item, and five were retained separately after comparing the raw claims. This
screen is navigation only. Broad path citations cause false matches; different
words or locations can hide a true overlap. The 30 merges also include explicit
cross-references and known source-backed subsets below the lexical threshold.

| Retained pair | Why it remains separate |
| --- | --- |
| `tests-1c-26` / `tests-2-07` | Both discuss serial tests, but one measures unit-wide serialization while the other addresses heavy TestSupport setup and isolated scheduling in a different suite. A common program may fix both; the source claims have different acceptance checks. |
| `github-b-14` / `tests-2-04` | The first surveys production test-seam dependencies; the second identifies a concrete `Transport.require_token` test credential path. Removing general seams does not by itself specify that credential behavior. |
| `tests-1c-26` / `tests-3-03` | Unit-wide serial execution and a large TestSupport helper have different direct remedies. A smaller helper is not proof that named global processes become parallel-safe. |
| `loose-3-06` / `web-rest-09` | TestReset and a presenter each reconstruct workspace paths incorrectly, but at separate input and execution boundaries. One fix does not necessarily repair the other. |
| `loose-1-42` / `loose-2-16` | Unknown freshness fields in `aiur commands` and a versioned CLI JSON envelope are different output contracts. They share CLI source, not the same failing branch. |

The merge set includes exact overlapping families such as the dead tmux event
channel, unbounded AgentQueueStore history, Build Order/OpenTicket overlays,
ControlCenterCache loading, durable meter parsing, hard-coded GitHub base
URLs, test environment restoration, and state-label normalization. It also
absorbs narrow source-backed duplication sweeps into their broader inherited
work item while retaining every original recommendation and location. Large
module findings stay separate from defects within those modules: a file split
alone does not establish a behavioral fix.

This is a conservative **planning** reconciliation. It does not prove all 986
remaining work items are pairwise semantically independent, validate every
P2/P3 claim, or measure a saving. Source-level skeptic verdicts cover the
182 inherited P0/P1 IDs only. Current-head and runtime checks are still
required before implementation tickets claim a present defect.

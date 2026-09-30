# Current-main citation update after workspace recovery

This is a static source-citation recheck, not a behavior test or runtime-incidence
claim. The same 986 canonical findings and frozen `3339b887` source were compared
at `04ef05c41` and current merged `main` at `220b8f253` using
`tooling/current_head_static_triage.py` without a correction ledger.

| Head | Identical cited lines | Stale citations | Unknown citations |
| --- | ---: | ---: | ---: |
| `04ef05c41` | 711 | 37 | 238 |
| `220b8f253` | 698 | 37 | 251 |

Thirteen findings moved from `current` to `unknown`; none moved to `stale`.
Their cited files changed in the merged workspace ownership recovery PR #2879:

| Area | Finding IDs |
| --- | --- |
| Agent lifecycle and ownership | `agent-backends-cc-05`, `agent-backends-cc-30`, `agent-runtime-40`, `dup-by-body-33`, `dup-by-body-48` |
| Workspace ownership | `platform-misc-03`, `platform-misc-04`, `platform-misc-14`, `platform-misc-29` |
| Ownership tests | `tests-6-08`, `tests-6-10`, `tests-6-11`, `tests-6-22` |

The changed line anchors need source recheck before an implementation ticket
uses them. This movement does not establish whether any cited defect was fixed,
regressed, or observed in a live run. The 37 stale and 251 unknown findings
remain explicit review queues.

Reproduce from a checkout containing both commits:

```sh
python3 docs/research/refactor-2026-09-26/tooling/current_head_static_triage.py \
  --findings docs/research/refactor-2026-09-26/review/findings.json \
  --base 3339b887196d5e9aefb273117a14bf33391ee41f \
  --head 220b8f25313acf92799f25af9a6db09583ef207d \
  --output /tmp/aiur-refactor-current-head-220b.json
```

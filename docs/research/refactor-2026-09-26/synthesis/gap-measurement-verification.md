# Gap measurement verification checkpoint

Checked on 2026-09-26 against retained historical inputs. This is an arithmetic
and interpretation check, not a completed source-completeness audit or a new
measurement of the running system. Aggregate totals include private-source
counts and durations (private); no private chronology or identifiers are added.

## Reproduced and corrected measurements

The independent `tooling/gap_measurement_audit.py` parses retained gap records
and activity events without importing or running the original analysis code.
All 202 original attendance fractions and category-bin counts reproduce.

| Measure | Retained >=15-minute gaps | Retained >=30-minute gaps |
|---|---:|---:|
| Gap count | 202 | 108 |
| Exact interval hours | 760.2576 | 727.7334 |
| Historical category-bin hours | 760.2500 | 727.8000 |
| Historical attendance fractions above one | 67 | 30 |
| Historical maximum fraction | 1.051 | 1.020 |
| Duration-weighted attended hours | 320.1309 | 288.4312 |
| Duration-weighted unattended hours | 440.1268 | 439.3021 |
| Gaps at least half attended, before / after | 178 / 178 | 86 / 86 |

The old calculation iterates `floor(start/60)` through `floor(end/60)-1`,
counts whole minutes and divides by exact elapsed minutes. A counted partial
first minute can contribute more seconds than the gap contains, while a
partial final minute is omitted. This explains the impossible fractions.
The correction intersects each qualifying minute with the exact gap interval,
including both boundary minutes. It does not simply clamp values to one.

`gaps/gaps.csv` preserves every preexisting cell and adds
`duration_weighted_attended_frac`. The original `attended_frac` is historical
provenance, not a valid bounded fraction. Category-minute columns retain their
old quantization; correcting attendance does not silently reclassify causes.

The five >=24-hour gaps total 447.8645 exact hours. Retained active-run spans
sum to 963.0758 h, yielding a 75.5635% >=30-minute gap share. These reproduce
arithmetic within the captured progress/uptime model. They do not establish
complete source coverage, uninterrupted uptime or absence of useful work.
Claim gaps-01 remains open for those checks.

## Attribution is not causal allocation

For run-log aiur/khala, the retained classifier gives 172.5667 h in b and
32.0000 h in c with waiting items: 78.1783% of its 261.6667 category-bin hours.
Infrastructure category d is 6.4833 h. All reasons containing `stranded` sum to
38.5167 h, rather than the 39.2 h obtained by treating each row's top reason
as if it described its whole duration.

Read alongside `verdicts/claims-gaps-attribution.json` and the prior
`verdicts/claims-gaps-12.json` (which contains gaps-10). The latter already
found that some purportedly stranded tickets were running and awaiting write
permission, while other intervals did expose a parked-entry dispatch defect.
It is cited as an earlier investigation, not newly repeated here.

The original `classify_minute` uses label state, recorded declines and attention
windows. It treats paused/error/review/decision states as human-waiting proxies,
and the absence of selected refusal/attention evidence as dispatchability. It
does not check fleet occupancy in that decision. A recorded later decline is
applied backward over the entire label-state episode. Precedence chooses one
bucket even when several potential causes coexist. Consequently 78% cannot
prove that the human operator is the bottleneck, and 2.5% cannot prove the
daemon accounts for only that share of delay.

The report has two different presence measures: category assignment uses
+/-5-minute activity and a 30-minute human-message window; its attendance
metric uses global assistant/tool/Codex/subagent activity within +/-60 minute
indices. A human-message-only event does not enter that attendance metric.
Neither measure proves that an absent transcript means an absent human.
Aiur also supports a coding agent as Executor, so Executor delay and human
delay must not be conflated.

## Reproduction and remaining work

```sh
python3 tooling/gap_measurement_audit.py "$LOCAL_GAP_SCRATCH"
```

To add the correction to a copy of the historical CSV:

```sh
python3 tooling/gap_measurement_audit.py "$LOCAL_GAP_SCRATCH" \
  --csv-input "$ORIGINAL_CSV" --csv-output "$NEW_CSV"
```

The CSV mode matches every row uniquely by retained measurement fields and
refuses ambiguous or missing identities. It writes a distinct output file.
Validation: all 202 old CSV rows and cells are unchanged; every new fraction
is between zero and one. A separate union-of-attendance-windows calculation
matched the corrected aggregate, and a fresh audit run reproduced the saved
JSON exactly.

Input fingerprints and complete aggregate results are in
`gap-measurement-audit.json`. Raw activity and private source records stay local.

Still required: complete the run/progress-source audit, distinguish positive
causal evidence from labels and silence, verify the August defect/deployment
history, validate the host-down timeline, and check session-boundary and wake
consumption interpretations. These findings do not complete those claims.

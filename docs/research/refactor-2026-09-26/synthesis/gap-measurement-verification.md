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
The completed bounded gaps-01 verdict rejects the compound uptime claim; source-completeness and corrected-lifetime reconstruction remain unresolved.

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

## Wake-consumption interpretation checked

Claim gaps-09 is checked in `verdicts/claims-gaps-wake-consumption.json`.
`wake-consumption-audit.json` reproduces the reported cursors and backlog counts:
352 / 1,529 for architecture-docs, 546 / 264 for archon, and 4,683 / 66 for aiur.
These are observations of retained streams and current cursor files, not
independently timestamped historical cursor snapshots.

The architecture-docs transcript contains 63 assistant limit responses between
19:05:58Z and 22:07:45Z on September 3, with a user reset message at 23:52:34Z.
There are 65 notification-like user records; they are not all proven independent
wake triggers. Continued errors until the reset are not established.
A successful wake-file tool result returned wake 419 at September 4 00:04:08Z,
above the still-observed cursor of 352. This proves the metadata was viewed,
not that someone completed the underlying action. It contradicts treating all
above-cursor records as unseen.

The frozen code acknowledges owner reads, leaves observer reads uncursored,
caps retained wakes with overflow reporting, and exposes stalled-consumer
status. Owner/observer acknowledgement handling already exists in the September
2 revision `84263f653`. Preserve these contracts and investigate escalation
against them. Cursor movement can also result from eviction, so per-consumer
acknowledgement and completed work need separate evidence.

Reproduction (local paths are inputs; no raw transcript text is emitted):

```sh
python3 tooling/wake_consumption_audit.py "$LOCAL_REPO_STATE" "$PUBLIC_PROJECT_SESSIONS"
```

Validation compared string and block-list transcript content against an
independent probe and correlated the later wake-file call with its successful
result. No cursor, ownership, acknowledgement or retention state was changed.
Whether out-of-band escalation succeeded during this incident remains open.

## Session-boundary association checked

Claim gaps-08 is checked in `verdicts/claims-gaps-boundaries.json` using
`gap-boundary-audit.json`. All historical tolerant hit counts and rounded
baselines reproduce. The strict preceding-boundary test reduces silence hits
from 22 to 19; 34 compaction records are 17 boundary/summary pairs. Only three
of six pooled limit matches use a limit window recorded for the same repository.
The updated source report presents these sensitivities and withdraws causal
or no-harm conclusions about silence, limits, handoff and compaction.

Reproduction: `python3 tooling/gap_boundary_audit.py "$LOCAL_GAP_SCRATCH"
"$LOCAL_REPO_STATE"` on one command line. Baseline active intervals are retained
at minute precision, so computed lifts are explicitly approximate. A fresh run
reproduced the saved audit, including 11 limit windows totaling 25.4660 h and
13.6197 h overlapping gaps. Raw inputs and private chronology remain local.

## Uptime identity and progress coverage checkpoint

The historical event-ID generator does **not** guarantee that dividing an ID
by one million yields a daemon boot identity. Persisted reservations survive a
restart; a restarted generator can emit the same quotient. Cold recovery can
also seed from an older durable maximum above wall time. Consequently a common
prefix cannot prove uninterrupted uptime. The analyzer's two-hour observed-up
docstring is not implemented: it appends the full inferred span.

See gap-uptime-contract.json for the historical source hash and a source-rule
arithmetic counterexample. This invalidates the asserted proof of pre-log
uptime, not the previously reproduced interval arithmetic. No corrected
denominator is yet established, and no percentage of wasted time is measured.

A separate source-coverage audit finds that architecture-docs was fetched but
its GitHub cache is not read by the archon-alias progress loader. Applying the
same inclusion rules finds 3,537 qualifying source records and **zero** inside
the retained >=30-minute gaps; this particular omission therefore changes the
retained gap total by zero hours. That negative sensitivity result does not
establish complete source coverage. Repeated audit output matches exactly.

The three run directories flagged as absent from the presentation table all
belong to khala and already appear in the retained analysis model. They are a
table-completeness issue, not three proven missing denominator intervals.
Matching Bash invocations also count without verified command success, so
the progress definition should not promise uniformly durable outputs.

## Headline denominator correction and verdict

The original gap builder unions spans within each repository, but the headline
and initial independent audit divided by the sum of run spans. The retained
per-repo unions total 961.9397 h; the raw sum is 963.0758 h, including 1.1361 h
overlap. The compatible model ratio is 75.6527%, versus the historical 75.5635%.
Neither is a measured wasted-time fraction. The audit JSON preserves the old
fields as provenance and adds explicit union-denominator fields.

Both gaps-01 lenses reject the claim as written. Exact interval arithmetic,
the 638.6 h cross-repo union at stored minute precision, and the five long gaps'
61.54% share are reproducible; continuous pre-log uptime is not proved by the
event-ID contract. See verdicts/claims-gaps-headline.json. No replacement
lifecycle census or complete progress-source coverage is claimed.

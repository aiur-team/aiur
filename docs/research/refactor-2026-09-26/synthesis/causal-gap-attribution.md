# Causal reading of the retained idle-gap timeline

The historical gap model records 108 intervals of at least 30 minutes,
totalling 727.7334 exact hours inside its inferred active spans. Its 727.8
category-bin hours and 75.6527% compatible-span ratio reproduce, but neither
is a measured share of useful time lost or a causal allocation. Event-ID
quotients do not prove daemon uptime, some selected progress events are only
attempted commands, and the activity corpus is incomplete. See
[measurement verification](gap-measurement-verification.md),
[the corrected source report](../gaps/gap-analysis.md), and
[the 60-claim audit](claim-question-audit.md).

## Evidence grades

| Observation | What the measured timeline establishes | What it cannot allocate |
| --- | --- | --- |
| Prewarm hold, August 20–21 | A successful tool result captured a starvation alert whose binding cause was `prewarm=checking`, with zero live agents and effective cap one. A later diagnosis records 31 ready tickets and zero live agents while prewarm remained checking. The selected wake group has 71 blocked and 70 resolved records, forming 70 ordered pairs and one unclosed block. [Source audit](prewarm-starvation-history.json). | These are direct point diagnoses and bounded event pairs. Their ID quotient is not a boot identity. The 257.2 pre-log aiur hours in classifier bucket d cannot be assigned to this defect; repair merge is not deployment evidence. |
| Dependency declines, September 20 | Six ticket declines occur within milliseconds at 01:08:38Z and name `:dependency`. At the first snapshot, two open roots remain in the finite graph; after one closes, the recorded graph reduces to paused ticket 41 as the open root outside those six tickets. Another ticket begins workspace creation in the same poll. [Source audit](dependency-gap-evidence.json). | The six admissions were blocked by dependencies at that poll. They do not prove that the whole fleet was blocked, that the operator alone caused the delay, or that every subsequent minute had no runnable work. |
| September 25 decision/usage window | A 9.8374-hour retained window contains 40 operator-decision and 39 usage-limit wake records, plus one pause request. The gap classifier assigns 573 of 591 minutes to b; extracted alerts have zero candidate-decline records inside the interval, while a graph replay finds multiple frontier blockers. [Source audit](dependency-gap-evidence.json). | Wake counts are co-occurring signals, not mutually exclusive durations. The 573 model minutes are not 573 proven human-blocked minutes; an earlier decline was projected backward across label state. |
| Host interruption, September 22–24 | Khala's last retained telemetry to its explicit next `daemon_restart` start spans 51.0999 hours. A host boot boundary and absent clean shutdown support an unclean termination reading. [Source audit](host-downtime-evidence.json). | The last old-boot journal entry is not the crash instant, no independent observation proves every minute was down, and historical external supervision/notification is unknown. This interval is outside the in-run gap denominator and must not be added to its category hours. |
| Largest August gap | The largest retained model gap is 151.3621 hours; three neighboring gaps total 173.2840 hours with 0.4704 hours between them. At its start, 12 human-review and five rework issues coexist with one todo issue already linked to an open PR. [Source audit](largest-gap-attribution.json). | A todo label plus missing refusal is not positive scheduler admission. An unresolved alert extended to an inferred ID-group end cannot prove 151 hours of infrastructure failure, and waiting labels cannot prove 151 hours of human absence. Leave this interval causally unassigned. |

The run-log aiur/khala model labels 172.5667 of 261.6667 category-bin hours
as b and 32.0000 hours as c with waiting items: **78.18% classified as
waiting**. It labels 6.4833 hours d. Those are precedence-selected proxy
states, not observed cause shares. The classifier uses label/attention state,
transcript presence and an absence of selected decline evidence, without a
positive occupancy and eligibility test for each minute. Coding-agent
Executors are first-class; even a verified Executor wait is not automatically
a human absence. The 144.4-hour private-source category-e entry remains an
aggregate modeled no-queue classification, with no private chronology here.

## Planning boundary

The demonstrated causes are *local*: a prewarm admission hold at recorded
points and dependency refusals for six candidates at one poll. The
telemetry-to-restart interruption is measured as an observation gap with a
host-termination interpretation. The evidence does not support a ranked
whole-population cause chart, a percentage of time saved by any one repair,
or a reassignment of all b/c/d hours. Gap-related rewrite requirements should
preserve prewarm recovery, dependency correctness, cause-neutral unknown
states, durable liveness observation and Executor action receipts while
instrumenting the missing per-interval facts: daemon identity/up state,
queued candidates, dependency frontier, positive admission/refusal,
capacity/occupancy, operator decision state, and progress-event outcome.
Only then can a new census estimate causal durations and compare before/after
rates on equivalent populations.

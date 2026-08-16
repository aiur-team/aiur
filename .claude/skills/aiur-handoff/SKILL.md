---
name: aiur-handoff
description: Write the Executor handoff document that the next Executor reads on boot. Use at an Executor handoff, before context exhaustion, when the operator says "write a handoff", or when a run is stopped or its goal cleared.
---

# Write an Executor handoff

The handoff is the only thing that survives you. Chat transcripts do not carry
over; a directive not written here has not been recorded.

## Where it goes

```
~/.aiur/repo/<owner>/<repo>/executor/handoffs/<UTC>-handoff.md   # the archive
~/.aiur/repo/<owner>/<repo>/executor/handoff.md                  # copy of the newest
```

Timestamp with `date -u +%Y%m%dT%H%M%SZ`. **Never overwrite an archived
handoff.** The archive is how successive runs are compared — an incoming
Executor reading three handoffs can see whether a fault is recurring, whether a
metric is trending, and which claims were later corrected. Overwriting destroys
exactly the evidence that makes the series worth keeping.

Copy the new file to `handoff.md` as well, because `aiur-run` reads that path on
boot.

## The format

Follow `handoffs/TEMPLATE.md` beside the archive. If it is missing, write it
from this skill. The sections are fixed so a reader can jump to what they need:
goal and its state, machine state, work completed, in-flight work, remaining
tickets, operator-specific context, the governing review rule, verification
rules, capability substitutes, meta-log index, and what to do next.

## What separates a useful handoff from a useless one

**Lead with whether the goal is still active.** If the operator cleared it or
stopped the fleet, say so in the first three lines. The worst failure mode is an
incoming Executor resuming a loop the operator ended.

**Measurements, not adjectives.** "The control path is fast now" is
unverifiable. "`status` 220 ms, was timing out at 5.2 s, measured with 15 agents
running" can be re-checked and disproved.

**Distinguish merged from verified.** They are different claims and the
difference is where this project keeps getting hurt. Say which surfaces you
checked on the running system and which you only merged.

**Record corrections, including your own.** If you reported something and it was
wrong, write that down with what the measurement actually showed. A handoff that
launders the outgoing Executor's mistakes sends the incoming one down the same
path. This is the single highest-value content in the document.

**Name what you did not do.** Silence reads as coverage. An unreviewed PR, an
unverified ticket, a check you skipped — say so.

**Carry the operator's words verbatim** where the wording matters: authority
grants, ownership boundaries, what "finished" means, communication preferences.
Paraphrase loses the constraint.

**Write for someone with no transcript.** Assume the reader knows the repository
and nothing about this run.

## Capability differences

If you know the incoming Executor's model, note any capability it lacks and give
a **working substitute** for each affected check — not just a warning. A reader
that cannot view images needs the command that extracts DOM counts and text, or
it will silently skip the visual verification step and report a page healthy.

## Before you finish

1. Re-read section 1. Does it state the goal's current status unambiguously?
2. Does every claim of "fixed" say how it was verified?
3. Would the reader know which of the open PRs need action and which land alone?
4. Is every operator directive from this run present, or only the ones you
   happened to remember?
5. Did you record at least one thing you got wrong? If not, check again — a run
   with no corrections usually means they were not noticed.

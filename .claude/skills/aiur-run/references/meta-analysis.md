## Hourly meta-analysis

**Set the timer at the start of the run and again on every resume** (pause,
goal set or resumed, compaction, new session); confirm it in your harness's job
list. The meta-check lives in the `aiur-meta` skill; arm a one-hour trigger:

- Claude Code: `/loop 1h /aiur-meta`
- any harness with a scheduler: a cron or wakeup at 3600s invoking `/aiur-meta`
- no scheduler available: fall back to `scripts/executor-retrospective.sh due`,
  which keeps a durable run-scoped timer, and check it on every wake

Do not rely on noticing that an hour has passed. An Executor deep in a merge
queue does not notice, and the checks that get skipped are exactly the ones that
would have caught the surface going quietly wrong — a provider meter frozen for
3.6 days (#1564), a blocker card stale for 5 days (#1565), a Build Order page
rendering an em-dash in every cell (#1616). None of those announced themselves.

`aiur-meta` owns what to observe and how: the four dashboard pages captured and
**looked at**, the interactive CLI timed and checked for empty responses, host
load against the configured gate, and the PR backlog. It ends by naming one
bottleneck and filing what is broken.

Alongside that, the meta-analysis of the work itself (proven repeatedly in the
2026-07 analytics-streamdeck run):

1. name THE single thing currently costing the most wall-clock, quantified —
   minutes lost, CI cycles burned, agents idle. Breadth summaries are not the
   deliverable; the organizing question is "what is the latest thing taking the
   most time, and how do we shrink it?" There is always a next bottleneck; when
   one falls, the next entry names its successor;
2. classify recurring problems, not incidents — ask what CLASS of failure
   recurred this hour (the known classes are listed below);
3. when a class recurs (rule of thumb: 3+ reproductions, or 2 with a shared
   root cause), file ONE systemic ticket attacking the class instead of
   patching more instances, recording the reproductions that justify it. At
   most 1-2 evidence-backed systemic tickets per pattern, and never expand the
   active feature boundary with them;
4. write and file the durable judgment in the repository state node: write the
   narrative retrospective to
   `~/.aiur/repo/<owner>/<repo>/meta/retros/<boot-id>.md` and pass each
   actionable JSON record through `aiurdev findings --record '<json>' --repo
   <owner>/<repo>`. This validated writer enforces the schema and atomic 4 KiB
   cap; never append the ledger directly. Include the reusable slug, evidence
   references, status, and ticket number (or `ticket: null` until it is filed).
   A finding without a ticket is not a completed retrospective:
   `aiurdev findings --unfiled` is the gate before treating the review as done.
   **A finding needs todo or an adopted Build Order queued marker.** An
   unlabelled ticket is inert — no agent can claim it and it appears in no
   state-scoped view — so filing one and moving on records the finding without
   scheduling the work. Set the dispatch state in the same command that creates
   it. An intentionally deferred finding receives `needs-triage` or
   `human:todo` with its reason instead; a ticket URL without either disposition
   is still unfiled for scheduling purposes.

   Raw state remains host-local; periodically run `mkdir -p docs/executor &&
   aiurdev findings --digest > docs/executor/open-findings.md`, inspect the
   regenerated file, and commit it to share the digest between machines;
5. daily, review the accumulated notes and ask whether any Aiur skill should
   change so the next run never rediscovers the lesson; land the concrete
   skill-doc edit as a small PR.

The findings ledger is `~/.aiur/repo/<owner>/<repo>/meta/findings.ndjson`.
`aiur init` creates it and its parent directories. It holds one JSON object per
line, each hard-capped at 4 KiB so `O_APPEND` stays atomic when two Executor
instances share a host. Cite evidence by reference - an issue number or a log
path plus line - never a pasted log dump.

Always write through `aiurdev findings --record '<json>' --repo <owner>/<repo>`.
Use `mkdir -p docs/executor && aiurdev findings --digest >
docs/executor/open-findings.md` for the cross-machine Markdown projection; do
not hand-edit that generated digest or write directly to the NDJSON ledger.

```json
{"slug":"vitest-glob-excludes-tests","observed_at":"2026-08-01T18:04:00Z","scope":"repo","observed_in":"aiur-team/aiur","instance":"executor-1","summary":"20 tests outside the configured vitest include glob never ran","evidence":["#1442","~/.aiur/logs/agent-1442.log:8812"],"cost":"5.8h","ticket":1451,"status":"filed"}
```

`slug` is a reusable kebab join key, so the same finding observed twice groups
into a recurrence count instead of a second entry to triage — that is what turns
the "3+ reproductions" rule above into a number you can read rather than one you
must remember. `scope` is `aiur` when the finding reproduces on any repository
and `repo` when it names this repository's tests, CI, or code. `status` moves
`open` -> `filed` -> `resolved`. A record left at `ticket: null` is deliberately
visible to the unfiled gate, not an accepted completed state.

The wake/outcome retrospective tunes monitoring cadence; this practice tunes
the run. Every hour (established on the 2026-07 analytics-streamdeck run,
where it repeatedly paid for itself):

1. **Name THE single thing currently costing the most wall-clock**, quantified:
   minutes lost, CI cycles burned, agents idle. Breadth summaries are
   explicitly not the deliverable; the organizing question is "what is the
   latest thing taking the most time, and how do we shrink it?" There is
   always a next bottleneck — this check is never complete. When one falls,
   the next entry names its successor.
2. **Classify recurring problems, not incidents.** Ask what CLASS of failure
   recurred this hour. Known classes worth pattern-matching against:
   - silent failure with a misleading symptom — seven distinct faults in one
     run all presented as "the fleet is idle" and none logged a reason;
   - PR bodies claiming more than the diff delivers;
   - tests that cannot fail;
   - flaky-test families sharing one mechanism: shared globals, leaked
     persistent state, silently-failed cache invalidation;
   - identity/gate mechanics: pusher vs author, opener vs committer.
3. **Reflect the pattern into higher-level solution tickets.** When the same
   class recurs — rule of thumb: 3+ reproductions, or 2 with a shared root
   cause — file ONE systemic ticket attacking the class rather than continuing
   to patch instances: a consolidated test-isolation refactor instead of
   per-test fixes, a shared-helper hardening instead of per-file migrations,
   an alerting gap instead of another manual check. Record in the ticket the
   reproductions that justify it. File at most 1-2 evidence-backed systemic
   tickets per pattern, and never expand the active feature boundary with
   them — process/infra tickets ride alongside the build order; feature
   tickets need operator sign-off.
4. **Write and file the entry** in the repository state node. The narrative
   retrospective is `~/.aiur/repo/<owner>/<repo>/meta/retros/<boot-id>.md`;
   each actionable item is an append-only `meta/findings.ndjson` record with a
   reusable slug, evidence references, and its filed ticket (or `ticket: null`).
   Write it only through `aiurdev findings --record '<json>' --repo
   <owner>/<repo>` so schema validation and the atomic size cap cannot be
   bypassed.
   `aiur init` creates the tree and `aiurdev findings --unfiled` makes a missing
   ticket visible before a retrospective can be treated as complete. Raw records
   remain host-local; periodically run `mkdir -p docs/executor && aiurdev
   findings --digest > docs/executor/open-findings.md`, inspect the regenerated
   file, and commit it. That generated digest is the deliberate git channel
   between machines, not a sync of host paths or boot IDs.

   The ledger contains one JSON object per line, hard-capped at 4 KiB so
   `O_APPEND` remains atomic when two Executor instances share a host. Cite
   evidence by reference - an issue number or a log path plus line - never a
   pasted log dump.

   ```json
   {"slug":"vitest-glob-excludes-tests","observed_at":"2026-08-01T18:04:00Z","scope":"repo","observed_in":"aiur-team/aiur","instance":"executor-1","summary":"20 tests outside the configured vitest include glob never ran","evidence":["#1442","~/.aiur/logs/agent-1442.log:8812"],"cost":"5.8h","ticket":1451,"status":"filed"}
   ```

   `slug` is a reusable kebab join key, so repeated observations group into a
   recurrence count. `scope` is `aiur` when the finding reproduces on any
   repository and `repo` when it names this repository's tests, CI, or code.
   `status` moves `open` -> `filed` -> `resolved`. A record left at
   `ticket: null` remains visible to the unfiled gate; it is not an accepted
   completed finding.
5. **Daily**, review the accumulated hourly notes and ask whether any Aiur
   skill should change so the next run never rediscovers the lesson. Capture
   that as a concrete skill-doc edit and land it as a small PR.

#### Report to the operator in a few lines

The durable log stays exactly as detailed as it is. This rule is about the chat
message only.

**Default to three to six lines for a routine hourly report — not three to six
sections.** Lead with what is broken or what changed. If nothing changed, say
so in one line; a long report that concludes "no change" is worse than a short
one.

**Length scales inversely with how long the operator has been silent.** A
direct question earns a full answer. An unprompted hourly report earns a
summary, and the tenth unprompted report in a row earns less than the first.
Silence is not an invitation to write more.

Cut by default: per-surface tables, context the operator already has restated,
narration of what was checked, and anything already written to the durable meta
log. The log is the place for completeness; the message is the place for the
headline.

Keep: the named bottleneck, anything needing an operator decision, corrections
to claims you previously reported, and measured numbers that changed.

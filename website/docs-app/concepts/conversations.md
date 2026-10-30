# Conversations

A conversation is the transcript for one worker ticket. Retries and provider
sessions belong to the same conversation; each session marks a separate period
of work. The journal also defines an Executor conversation identity, for the
[Executor](/concepts/executor) integration to use.

Each stored entry has an increasing position (`pos`). A position identifies an
entry within one conversation, across sessions and daemon restarts. It is not a
line number in a provider's log.

## Resolve a worker conversation

`GET /api/v1/conversations/resolve?subject=worker&owner=OWNER&repository=REPOSITORY&identifier=ID`
returns the matching `conversation_id`. Use `subject=executor` to resolve the
current Executor conversation. Worker resolution checks the current run first,
then the cached durable subject index.

An unreadable `subject.json` is skipped and logged, so it does not prevent
other workers from resolving. A missing subject returns 404, duplicate matches
return 409, and an unavailable conversation index returns 503.

The route uses the dashboard's read authorization.

## Where transcripts live

The daemon stores journals beneath its decision-state directory:

```text
<state-root>/<instance-key>/<project>/conversations/<conversation_id>/
  subject.json
  sessions.jsonl
  entries.000001.jsonl
  entries.000002.jsonl
  anchors.jsonl
  head.json
```

`<state-root>` is `AIUR_BG_STATE_DIR` when set; otherwise it is `.aiur-state`
under the daemon's working directory. The instance key comes from
`AIUR_INSTANCE_KEY`; the project is the sanitized last part of the tracker
project identity. Conversation IDs start with `conv_`. Read `subject.json` to
identify the worker ticket before removing a directory.

Directories have owner-only access (`0700`); files have owner-only read/write
access (`0600`). Entry files roll into a new segment at about 8 MiB. This does
not limit total conversation size. `head.json` is a rebuildable index.

The journal is separate from each agent workspace. Removing a workspace does
not remove its journal. Stored entries survive daemon restarts. Workspace
`logs/agent.md` and `logs/agent.ndjson` remain separate records; the current
quick conversation view can still read live or workspace history.

## How much space to allow

The [2026-10-14 census](https://github.com/aiur-team/aiur/issues/4453)
measured 341 usable recent workspace files, filtering events from October 7.
With a 64 KiB cap per record, storage rates were 604 KB/hour/agent at the median,
4.48 MB/hour/agent at the 90th percentile, and 11.31 MB/hour/agent at the maximum.

For 16 continuously active agents, those median and 90th-percentile rates
project to 0.232 and 1.720 GB/day.

These are capacity estimates from source logs,
not measurements of the current journal's mixed body limits. Idle time within
the measured span lowers these rates; actual use varies with the work.

The journal bounds each body and output field to 16 KiB for commands and tool
results, and 64 KiB for other entries. Long fields keep their beginning and end
with an omitted-byte marker. **The middle of very long outputs is not stored.**

A provider can also truncate output before the journal receives it.

## Retention and deletion

Transcripts stay on this machine until you delete them. There is no automatic
pruning. Closing a ticket or restarting Aiur does not delete its transcript.
Monitor free disk space on the state volume.

To delete one conversation:

1. Stop the daemon with `aiur stop` (or `aiurdev stop` for a dev run).
2. Find the conversation directory above and verify its `subject.json`.
3. Remove that exact `conversations/<conversation_id>/` directory, including
   its entry segments, sessions, anchors and index.
4. Restart Aiur when ready.

This removes the journal copy only. Provider logs, workspace logs, backups and
exported copies can still contain the same text. A later session can create a
new journal for that subject; deletion is not a recording opt-out.

## Reading entries

The full conversation chronology renders agent messages as Markdown. Reasoning
and command or tool output start collapsed; select their summaries to expand.
Commands show their exit code when nonzero, and tools distinguish success,
failure and unknown status. File edits show unified diffs, with lines after the
first 200 under an expandable summary.

Operator messages appear in a bubble; Executor messages carry an **Executor**
label. Provider input stays a labelled system row. Session dividers show the
start reason and time; recording gaps show their interval and reason. A
truncation note explicitly identifies output whose middle was not stored.

## Secrets

Transcripts can contain secrets printed by an agent or tool. Treat the raw
journal as sensitive even with owner-only permissions. Never commit or share
the directory.

The full conversation display masks likely secrets by default. Entries changed
by masking show **masked**. **Show raw** re-reads one entry and is available only
for loopback dashboard sessions with dashboard writing enabled. Device principals
always receive redacted bodies.

The worker quick drawer remains available on `/voice`, reachable from Home’s **Settings → Talk to Executor**. Display masking does not remove
secrets from disk and cannot guarantee that all secrets are detected.

## Jump points and precision

Jump points associate events with transcript positions. The catalogue covers
progress, phase changes, pushes, PR opens and merges, CI results, review
comments, Command requests and answers, attentions, and Executor progress.

Labels name identifiers and enums, such as “Progress 60%”, “Pushed 3f9a1c0”,
“PR #51 opened”, “CI failed”, and “Command answered”. Missing identifiers
leave a plain label; labels never copy comment bodies, PR titles or Command
text, and stop at 60 characters.

The catalogue defaults enable progress, pushes, PR opens and merges, and
Command requests and answers. Phase changes, CI results, comments, attentions
and Executor progress default off. These are navigation defaults, not event
recording filters.

The full conversation view and event filters are separate integrations; a
catalogue entry does not guarantee a visible link in every current surface.

Precision describes the strength of the link:

| Precision | Meaning |
| --- | --- |
| Exact | A tool-call identifier identifies the transcript entry that produced the event. |
| Causal | A successful push or PR command matches an event key within the prior ten minutes. |
| Approximate (observed) | The position is based on when the daemon observed the event, not proof of what produced it. |
| Not linked (unanchored) | No safe position is available; the event has no transcript jump target. |

Pushes match an output SHA range or new-branch destination; PR creation and
merges match the PR number in a URL or merge command. The latest matching
command wins; missing keys fall back to observed placement.

The same event can be observed in a worker conversation and causal in an
existing Executor conversation. Worker events without a matching Executor
command do not add Executor jump points.

Git `-C`/`-c` options and merge flags are supported. Merge body keys come from
the merge command's first positional target; a targetless merge can match its
output URL. PR number matching does not verify repository identity.

Missing tool provenance, unavailable timestamps, events outside a known
session, and gaps in recording can prevent a position. An approximate anchor
must not be read as an exact causal link. A Command request with matching
tool provenance can have an exact anchor.

## Earlier and imported history

The pre-journal importer is not yet integrated. Where an imported session
is available, it represents recovered provider or workspace history, rather
than a session recorded live by the journal. Do not assume all older sessions
can be recovered, or that recovered text has complete output or provenance.

“Earlier history is not available” means there is no readable earlier source;
it does not prove that no earlier work happened. The journal cannot recreate
text that its sources no longer contain.

## If recording degrades

`system.conversation.journal.degraded` means journal persistence failed.
Check the named conversation, disk space and state-directory permissions.
Agents can continue working while recording is degraded, so the transcript
can have gaps.

The writer retries recoverable failures and records detected
gaps after recovery; it cannot promise to recover every missing entry.

`system.conversation.journal.degraded.resolved` reports recovery. Corrupt
journals become read-only. Stop the daemon and preserve the files for diagnosis
before attempting repair; do not edit entry segments while the daemon runs.

## Deleting a voice transcript

An operator can delete a whole ended voice conversation with
`aiur voice transcripts <id> --delete --confirm <id>`. The confirmation must
repeat the same conversation ID; an active conversation must be ended first.
There is no bulk deletion or automatic retention policy.

Deletion removes the local transcript, including its text, context, drafts and
metadata. A content-free tombstone retains only the conversation ID, deletion
time and actor.

Deleted sessions disappear from transcript listings and no
longer contribute to local daily minute accounting. Interrupted deletions are
completed during boot reconciliation; an index rebuild preserves tombstones.

This action does not retract instructions or Command answers already delivered
to another conversation. Provider cleanup runs independently at session end.

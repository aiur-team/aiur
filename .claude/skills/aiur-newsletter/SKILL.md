---
name: aiur-newsletter
description: Prepare the daily Aiur newsletter, enrich its automated report with Executor context, compile the one-page PDF, and deliver it in Claude chat with a push notification. Use for /aiur-newsletter or a daily newsletter wake; dry-run prepares the PDF without sending.
---

# Daily newsletter

Run from the repository root containing `packages/newsletter/`. This is an
Executor workflow; it uses the package rather than implementing another collector
or renderer. Read `packages/newsletter/README.md` for the current CLI and notes
schema. No email, SMTP credentials, paid service, or new scheduler is needed.

## Preprocess

Identify the target `owner/repo`, configured instances and operator time zone
from the active run. Run:

```sh
python3 packages/newsletter/newsletter.py preprocess --repo <owner/repo>
```

Use `--state-dir <root>` for an explicit per-repository state root and repeat
`--instance <name>` for other configured machines. Read the printed `report.json`
and its source statuses before adding context. Work on that returned path; the
package uses UTC dates and the current report window, not an assumed local day.
An unavailable source stays `unavailable`; never infer zero or yesterday's value
from a seven-day average. Keep merged, proven live, and finished/verified separate.
Deduplicate shared issues and PRs across machines; never add their counts.

## Add Executor context

Read the latest Executor handoff at
`<state-root>/executor/handoff.md`, the report's linked meta/action evidence,
and the current run's Commands. Read open Commands with
`aiur command --filter open --json`; follow pagination if present. Check open
`human:todo` and `needs-triage` tracker items using the configured tracker.
A label alone does not establish a Kevin dependency: inspect the actual question
and whether only Kevin can answer or act. Recheck handoff questions against current
state; omit resolved, superseded and Executor-answerable decisions.

Write `notes.json` beside the report. Start from
[assets/notes.example.json](assets/notes.example.json), replacing every example
with observed facts. The package's `blockers` field is the “blocked by Kevin” list:
`{"label": "Package publication", "action": "Enable trusted publishing"}`.
Use this supported format rather than the earlier proposed
`blocked_by_kevin[{blocks,action,ticket}]` schema. Keep source ticket/Command links
in a private evidence record beside the notes, outside the rendered fields.

- Include every confirmed operator blocker with what it prevents and the exact
  action Kevin needs to take. Deduplicate items found in multiple sources.
- Set `"blockers": []` only after checking all three sources and finding none;
  the page then says “Nothing blocked on you today”. If any source is inaccessible,
  report the gap and omit `blockers` so it renders `unavailable`, not a false all-clear.
- Use `bottlenecks[{problem,action,result,tone}]` for constraints, actions actually
  taken and observed results. Say `Impact not measured` when appropriate. Omit
  this field to retain automated bottlenecks; override only with checked evidence.
- Use `shipped[{icon,label}]` only for observed outcomes, and `notes` for at most
  one summary line covering a decision, risk or finding automation cannot capture.

Use plain labels of about six words or fewer; each blocker label and action must
be under about ten words. No issue/PR numbers, ticket links, long paragraphs or
bullet essays in the PDF or notification. Prefer the template's bars, gauges and
stat tiles; do not restate computed numbers as prose. Never replace computed
metrics with editorial guesses. Omit unknown editorial fields; explicit empty
lists mean checked and none found. Do not copy secrets or machine-local paths
into editorial content. Preserve the full evidence privately even if the printed
page reports `+N more`.

## Compile and inspect

```sh
python3 packages/newsletter/newsletter.py compile <report.json> --notes <notes.json> --timezone <IANA-zone>
```

The command prints the PDF path and updates the report with the supplied notes.
It requires Chromium/Chrome and rejects overflow or a PDF longer than one page.
Inspect the generated HTML/PDF for readable labels, an explicit “Blocked by you”
section, source gaps and the intended reporting window. Confirm the printed PDF
exists and is nonempty. If collection, notes validation or compilation fails,
report the exact failure; never send an older PDF as today's success.

## Deliver or dry-run

For a **dry-run**, stop after compilation and inspection. Report the report,
notes and PDF paths and the one-line summary; send neither a file nor a push.
Use an explicit scratch `--state-dir` for fixture runs so they cannot overwrite
real snapshots. Mark fixture outputs as dry-run and never present them as live data.

For daily delivery, use Claude's `SendUserFile` tool to attach the compiled PDF
to the operator's current Claude chat, then use the Claude app's push notification
tool with one plain-word summary line. Discover the available tools in that
Executor session; never invent a tool call or substitute a filesystem path for
an attachment. Check the file-send result before notifying; check the push result
before claiming notification succeeded. If a tool is unavailable or fails, report
which delivery step failed and preserve the PDF for retry. Do not claim delivery.

Record the report window, PDF path and confirmed file/push outcomes beside the
report in a local delivery receipt. On a repeated daily wake, inspect that receipt:
retry only the failed delivery step, and avoid resending a confirmed attachment
or notification. An explicit request to resend may override this. No daily timer
or wake publisher is installed by this skill.

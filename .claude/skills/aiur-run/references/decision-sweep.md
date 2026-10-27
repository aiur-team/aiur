# Open decision sweep

Run this check after every `aiur executor-wait --json` cycle. The wait handles
wake delivery; the separate query catches decisions whose wake was missed.

The runnable stateful helper is
[`open-decisions-sweep.sh`](open-decisions-sweep.sh). Set `AIUR_CMD` to the CLI
and `AIUR_DECISIONS_SEEN_FILE` to a persistent per-run file, then invoke the
helper each cycle. It runs `aiur commands --filter open --json` and reads
`.data.page.decisions[]`; each row has `decision_id` (or `id`),
`ticket.identifier`, `blocking`, and `created_at`. Age is measured against the
envelope's `snapshot.captured_at`. Newly seen blocking decisions are printed
immediately, and remain visible whenever their age reaches 15 minutes. Report
the decision ID, ticket, and age, then handle or escalate it under the command
decision rules in the parent skill.

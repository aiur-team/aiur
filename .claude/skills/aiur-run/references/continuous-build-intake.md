# Continuous-build intake

Use this procedure whenever authorized to file a feature, epic, bug batch, or
experiment. Filing authority includes attaching that work to the repository's
single continuous build; it does not grant merge or implementation authority.
Keep the collection's finite acceptance boundary and research/design evidence.

1. Read `aiur queue show --json` and `aiur queue order`. Capture the previous
   next-up ticket, queue, rank, holds, and start trigger before any writes.
   Inspect existing features and tickets for ownership and real prerequisites.
2. Choose a new feature slug and create its collection with
   `aiur feature create <slug> --label "<display label>"`. New work in an existing
   feature uses that collection. Never create a standalone Build Order root.
3. Ensure the `feature:<slug>` GitHub label exists, then create each issue with
   that label, complexity, priority, and disposition in the same request.
   With the queue enabled, use `agent:queued` for new members so incomplete
   intake cannot dispatch them. Only an explicit operator exclusion leaves a
   filed ticket outside the build: use `needs-triage`/`human:todo` and its reason.
4. Write GitHub's native `blocked_by` relationships for every real prerequisite,
   including existing tickets outside this collection. Re-read those links.
   Priority and thematic grouping never create dependency edges. A queue's
   `--after` is local scheduling metadata, not a replacement for native links.
5. Join ownership with `aiur feature add <slug> <ids…>`. Do not use `--move` to
   steal existing ownership; resolve the mismatch, or use an also-affects link
   when another feature remains the owner. Read `aiur feature show <slug> --json`
   and verify member IDs and projected `feature:<slug>` labels. Label projection
   is asynchronous; a failed or unknown projection is not verified intake.
6. Add executable members using `aiur queue add <ids…> --queue <name>`.
   A feature collection and a queue are separate: neither membership implies
   the other. Use a list queue for new work, never `--build-order` adoption.
   Do not declare completion while queue status is disabled, unsupported,
   unavailable, or membership writes are partial: repair within authority or
   report the concrete blocker, keeping the intake incomplete.
7. **“Prioritize” means before the previous next-up.** Apply the operator's
   priority label (normally `priority:1` for an unqualified request), then set
   queue order too. In the same list, insert with `--at <zero-based position>`
   or move members with `aiur queue reorder <id> --to <position>`. For a new
   list, use `--rank <position>` on add or `aiur queue order <name> --to <position>`
   before the previous next-up set. Cross-set ranking requires
   `build_queue.set_order: ranked`; inspect the effective policy and enable it
   only within configuration authority, otherwise report placement blocked.
   Preserve true prerequisites, holds, and running work; prioritizing never
   preempts agents or bypasses readiness. If prerequisites prevent immediate
   pickup, report both the intended rank and the effective next eligible work.
8. Verify the collection in the continuous Build view. Until that view ships,
   use `aiur feature show <slug> --json` plus `aiur queue show --json`;
   `aiur build-orders` covers legacy roots only. Check ownership, GitHub labels,
   native links, queue membership, source freshness, and effective start order.
   Record the read-back and say “<new work> now precedes <previous next-up>”.
   A held/stale/unknown result cannot prove priority placement. Reconcile any
   failed step before reporting completion; the writes are not transactional.

Planning-only work records these proposed mutations and hands them to the
Executor. It must not claim that draft tickets have joined the live queue.
Historical Build Order roots stay readable; a new collection needs no root.

## Filing safeguards

Use `gh issue create --label ...`: the governed agent wrapper and Executor
`PreToolUse` hook reject creation without disposition and direct REST/GraphQL
creation that bypasses checked label flags. Never create first and label later.
Keep `gh issue list --search 'no:label'` as a safety-net audit before treating
queues as empty. Legacy roots carry `build-order`; explicit `Epic:` containers
carry `epic` and stay undispatched.

An `optimistic_blocker_failed` wake names the dependent, blocker, cause, and
action. Wait for a replacement blocker, re-base the dependent on the configured
base and resume it, or close it. Aiur keeps its branch and PR; recovery never
auto-resumes parked work. Info with action `none` means work keeps running.

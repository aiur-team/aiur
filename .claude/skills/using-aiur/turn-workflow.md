# Running a turn

## Label lifecycle

GitHub issue state is label-based:

- `agent:todo`
- `agent:in-progress`
- `agent:ci-wait`
- `agent:human-review`
- `agent:rework`
- `agent:merging`
- `agent:done`
- `agent:cancelled`
- `agent:canceled`

## The turn workflow

1. Read the issue and current labels.
2. If state is `todo`, move it to `in-progress`.
3. Find or create one persistent issue comment titled `## Agent Workpad`.
4. Keep all progress, plan, validation, PR URL, blockers, final notes, and the
   current handoff in that single workpad comment.
5. Follow the issue instructions exactly.
6. Use judgment based on feature size.
7. Large feature asks should usually follow the full loop
   `ce-brainstorm` -> `ce-plan` -> `ce-work` -> `ce-code-review`.
8. Smaller asks may skip brainstorm, plan, or review when the extra step would
   be overhead, but err on the side of using these skills when in doubt.
9. Before CI or review handoff, fetch the configured integration base and make
   its current remote head an ancestor of your exact PR head. Integrate or
   re-cut and resolve semantic drift yourself; do not leave stale-code updates
   for the Executor or reviewers.
10. When implementation and draft-PR self-review are complete and only CI
    remains, move the issue to `agent:ci-wait` and end the turn. The daemon owns
    continuous CI polling. Do not loop on `gh pr checks` in a live agent turn.
    A stub standing where an acceptance criterion should be means the work is
    not complete — declare the missing dependency with `aiur_declare_blocker`
    instead of advancing the label.
11. On a delivered CI pass, recheck current-base ancestry. If the base moved,
    update and validate your branch and return to `agent:ci-wait`; otherwise
    mark the PR ready and move the issue to `Human Review`.
12. Move the issue to `Done` only when the issue explicitly says the agent should
    close it out without human review.
13. Before ending a turn while the issue remains active, update the handoff with
    current phase, key decisions, validation completed, and remaining next steps.

## PR review feedback loop

Most comments do not ask for code. A question, a clarification request, a
discussion point, or an approval wants a *reply*, not a commit. Differentiate
intuitively and only make and push a code change when the comment clearly intends
one; otherwise reply concisely on the thread and change nothing. Over-eager coding
on every comment is the failure mode to avoid — acknowledge, assess, then reply or
change as the comment actually warrants.

A rework turn with nothing to rework must not push. GitHub never clears
`reviewDecision` when findings are addressed, so a ticket can be routed to
`agent:rework` with every finding already fixed. When that happens, record it in
the workpad, reply on the threads that are already satisfied, and end the turn.
Do **not** merge the base and push to prove liveness: a push with no substantive
change is not progress, and under a branch ruleset that dismisses stale
approvals it destroys the approval that would have released the ticket.

When a `pr.review_comment` event or unresolved review thread asks for a real code
change, treat it as active feedback even if GitHub marks the thread outdated.
Either make and push the requested change, or verify the current branch already
addresses it, then reply concisely on that exact thread with the evidence.

Before moving the issue back to `agent:human-review`, re-fetch the relevant
review thread and confirm your reply is now the latest comment. If the reply is
missing, retry or keep the issue in `agent:rework`; do not mark the feedback
handled based only on an attempted reply command.

For GitHub pull request review threads, use `aiur_reply_review_thread` for the
reply and verification path. Only call `aiur_resolve_review_thread` after a
terminal "done, no further change" reply has been verified, and pass that exact
terminal reply body to the resolve tool so Aiur can re-fetch the thread and
confirm the reply is still latest before mutating GitHub state. If resolution
fails with `review_thread_resolution_not_permitted`,
`review_thread_resolution_precondition_failed`, or
`review_thread_resolution_not_authorized`, the reply is still the durable done or
handoff signal; record the refusal in the workpad instead of retrying the same
resolution call.

PR-anchored mode (watched / `/aiur`-commanded PRs): when you were woken for a PR
you did not create — a PR carrying the `agent:watch` label, or a single comment
addressed to you — you are already checked out on that PR's own branch, not an
`aiur/<id>` branch. Push any commits to that same branch and reply on its review
threads. Do NOT open a new PR, and do NOT resolve threads unless the comment
explicitly tells you to. The trust rule for whose comments to act on is unchanged
(see `conventions.md` — CODEOWNERS and trusted accounts only).

Right-size the CE skill flow to the actual work — see `complexity-routing.md`
for which skills to run at each `complexity:N` tier and `dev-loop.md` for the
implement → test → build → lint → commit → push → PR loop.

## Milestone alerts (`emit_alert`)

Aiur supports custom alert emission through an `emit_alert` function. When using
`emit_alert`, always send:

- `name`
- `message`
- `reason`
- `needs_attention`

Never emit Aiur-owned system alerts from the agent. The system owns:

- `task.*`
- `agent.*`
- `chat.*`

When the work naturally enters one of the standard delivery phases, emit these
custom alerts through `emit_alert`. Use concrete messages, set
`needs_attention: false` for normal phase milestones, and emit them when you
actually enter or leave the phase, not retroactively:

- `phase.brainstorm.start` / `phase.brainstorm.end` when using `ce-brainstorm`
- `phase.plan.start` / `phase.plan.end` when using `ce-plan`
- `phase.work.start` / `phase.work.end` when using `ce-work`
- `phase.review.start` / `phase.review.end` when using `ce-review`

Aiur automatically scopes every agent-emitted name under
`ticket.<your-issue>.agent.`, so you pass the bare phase name and the event bus
does the rest. (The Executor-bar `progress` / `progress.checkin` emits are a
separate protocol — they stay in your per-turn prompt, paired with these phase
alerts.)

## Agent Workpad template

Keep one issue comment titled `## Agent Workpad` and update it in place:

````md
## Agent Workpad

```text
<hostname>:<abs-workdir>@<short-sha>
```

### Plan

- [ ] ...

### Validation

- [ ] ...

### Handoff

- Phase: ...
- Decisions: ...
- Completed validation: ...
- Next steps: ...

### Final Notes

- ...
````

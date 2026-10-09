# Aiur Events — Stub then fetch

The pattern for getting work done while waiting on another ticket.

Declaring a blocker is not a reason to park the whole ticket. It records the
dependency, subscribes you to blocker events, and marks only the integration
point as blocked. Keep independent work moving unless the blocker makes the
entire ticket impossible.

## Optimistic start (started on an unmerged blocker)

Use this mode only when your prompt contains an **Optimistic start** block.
Never guess it from a branch or an event. Without that block, the paused-dependent
rules below apply: a push is never a readiness signal. For an optimistic worker,
every blocker push is an integration signal.

1. **First turn.** Set `workspace="$AIUR_AGENT_WORKSPACE"`. For each blocker
   listed in the prompt, fetch its validated ref and SHA; never reconstruct a
   branch from its ticket number. Verify the fetched commit matches the supplied
   SHA. Run `git -C "$workspace" merge-base --is-ancestor <sha> HEAD`;
   merge each missing head with `git -C "$workspace" merge <sha>`, resolving
   conflicts hunk by hunk. Record each integrated blocker identifier, ref and
   SHA in the Agent Workpad. Keep the old commit reachable with a local rescue
   ref so a later rewrite can still be compared and rebased.
2. **Every `ticket.N.branch.push`.** At the next safe checkpoint (WIP
   committed, no test run in flight), fetch the payload ref and SHA and verify
   the commit. If several pushes queued for the same blocker, integrate the
   latest validated push. Read `<old>` from the workpad and run
   `git -C "$workspace" merge-base --is-ancestor <old> <new>`.
   Exit 0 means merge `<new>`; exit 1 means rewritten history, so use
   `git -C "$workspace" rebase --onto <new> <old>` to replay your commits.
   Any other exit is an error: stop integration and report it. Do not merge a
   rewritten blocker branch. Resolve conflicts without discarding either
   ticket's intent. The local ancestry check is authoritative on every push;
   `branch.force-push` is only a hint, including delayed or missing verdicts.
3. **Validate and publish.** Inspect `git -C "$workspace" diff <old> <new>`
   and rerun the repository's documented tests affected by that incoming diff,
   plus your own touched tests. In Aiur, use `mix aiur.affected_tests` with
   the old SHA as its base; include tests identified by the incoming diff and
   run the selected tests with
   `--max-cases 4`. After a rewrite, verify the PR is still draft and push
   your existing branch with `--force-with-lease`; otherwise push normally.
   Record the new integrated SHA only after successful integration and tests.
   Keep the previous SHA and concrete failure in the workpad if integration fails.
4. **Keep the PR draft and stacked.** With one unmerged blocker, use its branch
   as the PR base; with several, use `$AIUR_BASE_BRANCH`, as the prompt block
   directs. While any blocker PR is unmerged, never run `gh pr ready` or move
   to `agent:ci-wait` or `agent:human-review`, even if your own work and
   draft checks are complete.
5. **Own work done, blocker unmerged: park.** Leave the published PR draft,
   record the remaining blocker(s) and integrated SHAs in the workpad, and emit
   each event once without polling or retrying:
   ```jsonc
   { "name": "blocked", "message": "Own work complete; awaiting blocker #N merge", "payload": { "reason": "awaiting_blocker_merge" } }
   { "name": "pause.request", "message": "Awaiting blocker #N merge", "payload": { "reason": "dependency", "blocker_identifier": "N" } }
   ```
   For several blockers, name the outstanding blocker in the dependency pause;
   after each wake, reassess the remaining blockers and park again if necessary.
6. **On `ticket.N.pr.merged`.** Follow G3's restack procedure when available.
   Until that section lands: fetch the configured integration branch, retarget
   the PR to `$AIUR_BASE_BRANCH` and verify its base, then rebase onto the base
   tip dropping the blocker commits already included by the squash. Use the
   recorded integrated blocker SHA as the old boundary for
   `git -C "$workspace" rebase --onto <base-tip> <integrated-blocker-sha>`.
   Inspect the resulting diff to ensure your changes remain, rerun affected
   tests and push the draft with `--force-with-lease`. If another blocker is
   unmerged, keep the PR draft and follow steps 2–5; only after all blockers
   merge may you use the normal ready/CI handoff.

## When you're blocked on a function from ticket N

1. **Declare the blocker.** `aiur_declare_blocker(N)` — this records the dependency on GitHub natively and auto-subscribes you to the useful subset of ticket N's events.
2. **Separate owned code from prep.** Do not reimplement ticket N's helper, API, schema, or shared module. Do keep writing caller-side scaffolding, config, tests, imports, TODO integration points, and any other code that can safely wait for the real branch.
3. **Write a stub only when useful.** Based on the agreed signature (in the brainstorm, plan, or the parent issue's description), write a minimal stub that returns plausible-but-wrong values. Don't ship the stub — keep it local. A stub may let your local tests run, but it must never be pushed over files owned by ticket N or left in the branch you publish.
4. **Required: emit `unblocked` once.** This is a fire-and-forget call: enqueue
   it once and continue without waiting, polling, or retrying. Include
   `payload: {temporary_stub: true}` so subscribers know your "unblocked" is
   provisional:
   ```jsonc
   { "name": "unblocked", "message": "Stubbing function_a; waiting on real impl from #N", "payload": { "temporary_stub": true, "stubbed_function": "function_a" } }
   ```
5. **Keep working.** Use the stub as if it were real. Your other code (the part that depends on the stub) is now testable. If you cannot stub, keep doing the independent prep from step 2 and park only the blocked integration point.

## When the real implementation arrives

The blocker must commit and push the dependency before emitting readiness. Its
final `unblocked` payload must carry the same validated `ref` and `sha` as that
push. Aiur accepts it as readiness only after a matching validated branch-push
event has been observed, so readiness and the exact code to consume agree.
You'll get a
`ticket.N.agent.unblocked` event through the mid-turn checkpoint
drain. That explicit signal says the dependency is ready to consume. A
`ticket.N.branch.push` may arrive earlier, but it is only an inspect-and-stack
cue; never infer readiness from the push alone. Then:

1. **Fetch the actual branch.** Use the validated `ref` carried by the final unblock event, together with its `sha` (and corroborated by the branch-push event); its numeric topic key cannot recreate a readable title suffix. If no event ref is available, run `scripts/resolve-ticket-branch N` and use the branch it prints. Never construct `aiur/N` yourself.
2. **Inspect the pushed code before deciding.** Read the blocker diff and exports against that fetched ref, plus the relevant files or package indexes. Decide whether the needed helper/API actually landed.
3. **If the branch contains usable code, stack on it.** Commit your WIP if needed, then rebase or merge onto the fetched blocker ref instead of waiting for main. If the blocker PR is still open, open your PR against the blocker branch.
4. **Replace the stub.** Delete your temporary stub and import/use the real function. Do not push a branch that replaces blocker-owned files with local placeholders.
5. **Summarize what you adopted.** In your workpad or PR notes, say which blocker diff/export you found and which helper/API you integrated.
6. **Run your tests, commit, and push.** They were green against the stub; verify they're still green against the real implementation, then publish the integrated commit before announcing readiness.
7. **Required: emit `unblocked` again** without `temporary_stub`, carrying the
   exact ref and SHA you just pushed. This is also a
   single-attempt fire-and-forget call: enqueue it and continue without waiting,
   polling, or retrying:
   ```jsonc
   { "name": "unblocked", "message": "Integrated real function_a from #N", "payload": { "ref": "refs/heads/aiur/N-title", "sha": "<pushed commit>" } }
   ```

If the branch push is irrelevant or unusable, remain blocked only on that integration point and state the concrete reason: what you inspected, what was missing or incompatible, and what signal would make it usable.

## When you can NOT stub

Some blockers can't be reasonably stubbed — schema migrations that need to land before your code can compile, secrets that have to be rotated in shared infra, infra changes the Executor must approve. In those cases:

1. Declare the blocker (`aiur_declare_blocker(N)`).
2. **Required: emit `blocked` once** with
   `payload: {stubbable: false, reason: "..."}`. Treat the call as
   fire-and-forget: enqueue it once and continue without waiting, polling, or
   retrying.
3. Emit `pause.request` with
   `payload: {reason: "dependency", blocker_identifier: "N"}`. Aiur assigns a
   local pause generation and binds any retained readiness to that exact
   dependency pause; unrelated operator, label, CI, or duration pauses cannot
   consume it.
4. Stop working on the dependent code only. Pick up unrelated or preparatory work on the same ticket.
5. When the corroborated `ticket.N.agent.unblocked` arrives, return to the blocked work.

## When you produce a dependency

If another ticket has declared yours as a blocker, you are responsible for the
readiness signal even when your ticket has no dependency of its own. Commit and
push the promised API first, then emit exactly one final `unblocked` carrying
that pushed `ref` and `sha`. A branch push alone is never a readiness signal,
and an unblock whose metadata does not match the observed push is ignored.

## What NOT to do

- **Don't poll or retry emissions.** Required means every agent makes the call;
  fire-and-forget means it enqueues once and continues even when publication is
  still pending.
- **Don't mark an optimistic PR ready while a blocker is unmerged, or merge rewritten blocker history.** Follow the Optimistic start section above.
- **Don't infer readiness from `branch.push` for paused dependents.** Resume and integrate on the
  blocker's explicit `agent.unblocked`; use a push only to inspect its validated
  ref.
- **Don't silently use a stub.** Always emit `unblocked` with `temporary_stub: true` so other agents reading your `progress.*` events know to read carefully.
- **Don't skip the integration step.** Once the real implementation lands, replace the stub — leaving the stub in is a high-cost recurring bug.
- **Don't publish temporary stubs.** Stubs are local-only scaffolding. If the actual fetched blocker ref has the real helper/API, stack on that branch and remove your placeholder before pushing.

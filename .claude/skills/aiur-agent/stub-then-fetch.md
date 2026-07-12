# Aiur Events — Stub then fetch

The pattern for getting work done while waiting on another ticket.

Declaring a blocker is not a reason to park the whole ticket. It records the
dependency, subscribes you to blocker events, and marks only the integration
point as blocked. Keep independent work moving unless the blocker makes the
entire ticket impossible.

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

You'll get a `ticket.N.agent.unblocked` event through the mid-turn checkpoint
drain. That explicit signal says the dependency is ready to consume. A
`ticket.N.branch.push` may arrive earlier, but it is only an inspect-and-stack
cue; never infer readiness from the push alone. Then:

1. **Fetch the actual branch.** Use the validated `ref` carried by the branch-push event; its numeric topic key cannot recreate a readable title suffix. If no event ref is available, run `scripts/resolve-ticket-branch N` and use the branch it prints. Never construct `aiur/N` yourself.
2. **Inspect the pushed code before deciding.** Read the blocker diff and exports against that fetched ref, plus the relevant files or package indexes. Decide whether the needed helper/API actually landed.
3. **If the branch contains usable code, stack on it.** Commit your WIP if needed, then rebase or merge onto the fetched blocker ref instead of waiting for main. If the blocker PR is still open, open your PR against the blocker branch.
4. **Replace the stub.** Delete your temporary stub and import/use the real function. Do not push a branch that replaces blocker-owned files with local placeholders.
5. **Summarize what you adopted.** In your workpad or PR notes, say which blocker diff/export you found and which helper/API you integrated.
6. **Run your tests.** They were green against the stub; verify they're still green against the real implementation.
7. **Required: emit `unblocked` again** without `temporary_stub`. This is also a
   single-attempt fire-and-forget call: enqueue it and continue without waiting,
   polling, or retrying:
   ```jsonc
   { "name": "unblocked", "message": "Integrated real function_a from #N" }
   ```

If the branch push is irrelevant or unusable, remain blocked only on that integration point and state the concrete reason: what you inspected, what was missing or incompatible, and what signal would make it usable.

## When you can NOT stub

Some blockers can't be reasonably stubbed — schema migrations that need to land before your code can compile, secrets that have to be rotated in shared infra, infra changes the operator must approve. In those cases:

1. Declare the blocker (`aiur_declare_blocker(N)`).
2. **Required: emit `blocked` once** with
   `payload: {stubbable: false, reason: "..."}`. Treat the call as
   fire-and-forget: enqueue it once and continue without waiting, polling, or
   retrying.
3. Stop working on the dependent code only. Pick up unrelated or preparatory work on the same ticket.
4. When `ticket.N.agent.unblocked` arrives, return to the blocked work.

## What NOT to do

- **Don't poll or retry emissions.** Required means every agent makes the call;
  fire-and-forget means it enqueues once and continues even when publication is
  still pending.
- **Don't infer readiness from `branch.push`.** Resume and integrate on the
  blocker's explicit `agent.unblocked`; use a push only to inspect its validated
  ref.
- **Don't silently use a stub.** Always emit `unblocked` with `temporary_stub: true` so other agents reading your `progress.*` events know to read carefully.
- **Don't skip the integration step.** Once the real implementation lands, replace the stub — leaving the stub in is a high-cost recurring bug.
- **Don't publish temporary stubs.** Stubs are local-only scaffolding. If the actual fetched blocker ref has the real helper/API, stack on that branch and remove your placeholder before pushing.

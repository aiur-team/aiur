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
4. **Emit `unblocked`.** With `payload: {temporary_stub: true}` so subscribers know your "unblocked" is provisional:
   ```jsonc
   { "name": "unblocked", "message": "Stubbing function_a; waiting on real impl from #N", "payload": { "temporary_stub": true, "stubbed_function": "function_a" } }
   ```
5. **Keep working.** Use the stub as if it were real. Your other code (the part that depends on the stub) is now testable. If you cannot stub, keep doing the independent prep from step 2 and park only the blocked integration point.

## When the real implementation arrives

You'll get a `ticket.N.branch.push` event (or the mid-turn checkpoint drain will deliver it if it's blocking-critical for you). Treat that event as an inspect-and-stack cue, not a passive notification. Then:

1. **Fetch the branch.** `git fetch origin aiur/N`.
2. **Inspect the pushed code before deciding.** Read the blocker diff and exports: `git log --oneline HEAD..origin/aiur/N`, `git diff --stat HEAD..origin/aiur/N`, `git diff --name-only HEAD..origin/aiur/N`, and the relevant files or package indexes. Decide whether the needed helper/API actually landed.
3. **If the branch contains usable code, stack on it.** Commit your WIP if needed, then rebase or merge onto `origin/aiur/N` instead of waiting for main. If the blocker PR is still open, open your PR against the blocker branch.
4. **Replace the stub.** Delete your temporary stub and import/use the real function. Do not push a branch that replaces blocker-owned files with local placeholders.
5. **Summarize what you adopted.** In your workpad or PR notes, say which blocker diff/export you found and which helper/API you integrated.
6. **Run your tests.** They were green against the stub; verify they're still green against the real implementation.
7. **Emit `unblocked` again** without `temporary_stub`:
   ```jsonc
   { "name": "unblocked", "message": "Integrated real function_a from #N" }
   ```

If the branch push is irrelevant or unusable, remain blocked only on that integration point and state the concrete reason: what you inspected, what was missing or incompatible, and what signal would make it usable.

## When you can NOT stub

Some blockers can't be reasonably stubbed — schema migrations that need to land before your code can compile, secrets that have to be rotated in shared infra, infra changes the operator must approve. In those cases:

1. Declare the blocker (`aiur_declare_blocker(N)`).
2. Emit `blocked` with `payload: {stubbable: false, reason: "..."}`.
3. Stop working on the dependent code only. Pick up unrelated or preparatory work on the same ticket.
4. When `ticket.N.agent.unblocked` arrives, return to the blocked work.

## What NOT to do

- **Don't poll.** Don't burn turns checking `git log origin/aiur/N` repeatedly. Events fire automatically.
- **Don't silently use a stub.** Always emit `unblocked` with `temporary_stub: true` so other agents reading your `progress.*` events know to read carefully.
- **Don't skip the integration step.** Once the real implementation lands, replace the stub — leaving the stub in is a high-cost recurring bug.
- **Don't publish temporary stubs.** Stubs are local-only scaffolding. If `origin/aiur/N` now has the real helper/API, stack on that branch and remove your placeholder before pushing.

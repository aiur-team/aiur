# Aiur Events — Stub then fetch

The pattern for getting work done while waiting on another ticket.

## When you're blocked on a function from ticket N

1. **Declare the blocker.** `aiur_declare_blocker(N)` — this records the dependency on GitHub natively and auto-subscribes you to the useful subset of ticket N's events.
2. **Write a stub.** Based on the agreed signature (in the brainstorm, plan, or the parent issue's description), write a minimal stub that returns plausible-but-wrong values. Don't ship the stub — keep it local.
3. **Emit `unblocked`.** With `payload: {temporary_stub: true}` so subscribers know your "unblocked" is provisional:
   ```jsonc
   { "name": "unblocked", "message": "Stubbing function_a; waiting on real impl from #N", "payload": { "temporary_stub": true, "stubbed_function": "function_a" } }
   ```
4. **Keep working.** Use the stub as if it were real. Your other code (the part that depends on the stub) is now testable.

## When the real implementation arrives

You'll get a `ticket.N.branch.push` event (or the mid-turn checkpoint drain will deliver it if it's blocking-critical for you). Then:

1. **Pull the branch.** `git fetch origin aiur/N` and integrate.
2. **Replace the stub.** Delete your stub; use the real function.
3. **Run your tests.** They were green against the stub; verify they're still green against the real implementation.
4. **Emit `unblocked` again** without `temporary_stub`:
   ```jsonc
   { "name": "unblocked", "message": "Integrated real function_a from #N" }
   ```

## When you can NOT stub

Some blockers can't be reasonably stubbed — schema migrations that need to land before your code can compile, secrets that have to be rotated in shared infra, infra changes the operator must approve. In those cases:

1. Declare the blocker (`aiur_declare_blocker(N)`).
2. Emit `blocked` with `payload: {stubbable: false, reason: "..."}`.
3. Stop working on the dependent code. Pick up unrelated work (other unblocked tasks on your ticket).
4. When `ticket.N.agent.unblocked` arrives, return to the blocked work.

## What NOT to do

- **Don't poll.** Don't burn turns checking `git log origin/aiur/N` repeatedly. Events fire automatically.
- **Don't silently use a stub.** Always emit `unblocked` with `temporary_stub: true` so other agents reading your `progress.*` events know to read carefully.
- **Don't skip the integration step.** Once the real implementation lands, replace the stub — leaving the stub in is a high-cost recurring bug.

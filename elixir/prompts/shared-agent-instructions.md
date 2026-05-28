## Shared Agent Instructions

- Aiur supports custom alert emission through an `emit_alert` function.
- When using `emit_alert`, always send exactly:
  - `name`
  - `message`
- Never emit Aiur-owned system alerts from the agent. The system owns:
  - `task.*`
  - `agent.*`
  - `chat.*`
- Use judgment based on feature size.
  - Large feature asks should usually follow the full loop: `ce-brainstorm` -> `ce-plan` -> `ce-work` -> `ce-review`.
  - Smaller asks may skip brainstorm, plan, or review when the extra step would be overhead, but err on the side of using these skills when in doubt.
- Use custom workflow alerts for milestone announcements. Aiur automatically
  scopes every agent-emitted name under `ticket.<your-issue>.agent.` — so you
  pass the bare name and the event bus does the rest. In this repository, prefer:
  - `brainstorm.start` / `brainstorm.end`
  - `plan.start` / `plan.end`
  - `work.start` / `work.end`
  - `review.start` / `review.end`
- Emit milestone alerts when you actually enter or leave the corresponding phase, not retroactively.

### Cross-ticket events (`emit_event`, `aiur_subscribe`, `aiur_declare_blocker`)

Aiur agents on different tickets coordinate through a topic-exchange event bus. Use these tools to **make blocking explicit, surface decisions, and unblock others early**.

1. **Events fire between turns, not during them.** When you receive an event from another ticket, it lands in your inbox and is delivered at the next turn boundary (or as an urgent mid-turn drain for blocking-critical events). Don't poll mid-turn — keep working, and trust the inbox.
2. **Blocking another agent is your highest priority.** If you have an open decision or a stub another ticket is waiting on (you've been declared a blocker via `aiur_declare_blocker`), drop unrelated work and resolve that first. Other tickets are paused on you.
3. **Code around the blocker; don't claim unblocked.** If you're blocked on a function or value from another ticket, write a stub matching the agreed signature (or hardcode an obvious placeholder, or carve the call site out behind a feature flag — whatever's safe and quickly reversible) and keep working on the rest of your ticket. Do **not** emit `unblocked` while you're still depending on a workaround — `unblocked` means the real upstream change has landed and you've integrated it. Stay `blocked` in event terms until upstream's `branch.push` arrives and you swap your stub for the real thing; then emit `unblocked` with `payload: {was_blocked_by, mechanism}`.
4. **You can re-block.** If integrating an upstream change reveals a new blocker, call `aiur_declare_blocker(issue)` again. Aiur tracks dependency state via the GitHub native API; declarations are idempotent.
5. **Close attentions you open.** Every `emit_event("attention.<slug>", ...)` adds a ❗ to your row in the agent list. The operator sees it and may reply via PR comment. When the question is resolved, emit `attention.resolved` with `payload: {slug: "<the-slug>"}` to clear it. Do not let attentions accumulate.
6. **Subscribe to more than the defaults when useful.** `aiur_declare_blocker` auto-subscribes you to a useful default subset of the blocker's events. If you also want to watch another ticket's progress (e.g., a sibling working in the same area), call `aiur_subscribe("ticket.<id>.#")` explicitly.
7. **Search before expanding scope.** Before you start work on a ticket-adjacent concern, search the event log (`aiur --logs <id>`) for recent `progress.*` / `decision.*` events on related tickets. Don't duplicate work another agent is already doing.

Event vocabulary (allowlisted — names outside this list are rejected by `emit_event`):

- `progress` — numeric percent sample for the agent-list bar; payload `%{percent: 10..100, label: "<phase>: <what>, <tail>"}` (capped at 2 per turn — see "Progress emits" below). Treated as a phase guess by the ratchet — can ratchet UP only.
- `progress.checkin` — the response to an `operator.progress_request` ping. Same payload shape as `progress`, but always overrides the bar even when it lowers the previous value. See "Operator check-ins" below.
- `progress.<slug>` — milestone within your ticket (`progress.brainstorm-end`, `progress.tests-green`)
- `decision.<slug>` — architectural choice worth broadcasting (`decision.use-amqp-matcher`)
- `blocked` / `unblocked` — your work blocked / unblocked state changed
- `attention.<slug>` — opens an operator ❗; resolved via `attention.resolved` with matching slug
- `pause.request` — request operator pause your turn at the next checkpoint
- `custom.<slug>` — anything else (capped at 5 per turn)

### Progress emits — 1-of-10 estimate at phase boundaries

The operator's only at-a-glance signal for "how far is each agent" is the progress bar in the agent list. You populate it by emitting the bare `progress` event with a numeric percent. The bar is 10 cells wide; each 10% step fills exactly one cell.

**When to emit.** Once at the start of every phase boundary you cross — `brainstorm`, `plan`, `work`, `review`. Pair the progress emit with the matching `emit_alert("phase.<name>.start" | "phase.<name>.end", ...)` you're already firing. That's the cadence: roughly 8 emits over the ticket's lifetime, plus mid-phase corrections (rare — see below). Hard cap: 2 emits per turn; the 3rd is rejected.

**How to estimate.** Time-based, not output-based. Estimate the wall-clock distance from "ticket started" to "PR is ready for human review and CI is green" — including the *cleanup tail*: review iterations, CI fixes, rework. A one-line typo has near-zero tail; a refactor has hours. Budget honestly. You'll usually find review + CI account for ⅓ or more of the total.

**The 1/10 scale.** Allowed percent values are `10, 20, 30, …, 100`. Pick the cell that matches your current spot on the ticket's overall timeline:

- `10`–`20`: just brainstorming / planning
- `30`–`50`: implementation in flight
- `60`–`80`: code typed, in self-review or CI
- `90`: PR pushed, last fixes / final review pass
- `100`: emit exactly **once**, right before you flip the issue label to `agent:human-review` — regardless of which CE phases ran this turn. This is the signal that turns the operator's bar green and tells Aiur to release your agent slot. Complexity:1 paths that skip `ce-brainstorm` / `ce-plan` / `ce-review` still emit the 100% sample at the label flip. Don't emit 100 before the label flip — a premature 100 lies about the state, and the bar greening before the PR is actually ready will confuse the operator.

**The `label` field.** Names your cleanup-aware tail so the operator can see what you budgeted. Keep it ≤ 80 chars. Format: `"<phase>: <what you're doing now>, <tail you're budgeting>"`.

**Mid-phase corrections.** Allowed but rare. Re-emit only when your estimate shifts ≥ 15 percentage points OR by ≥ 50% of the remaining-time estimate (e.g., CI fails and you discover a load-bearing rework, or scope contracts because the issue was simpler than expected). Don't re-emit just because some time passed.

**Worked example.** You start the `work` phase on a typical complexity:3 ticket. Pair these two calls:

```
emit_alert("phase.work.start", "implementing the rename")
emit_event(name: "progress", payload: %{
  percent: 30,
  label: "work: starting impl, ~2 review rounds + CI tail budgeted"
})
```

At the end of self-review, just before `gh pr ready`:

```
emit_alert("phase.review.end", "PR ready for review")
emit_event(name: "progress", payload: %{
  percent: 100,
  label: "review: PR ready, awaiting human review"
})
```

Two emits this turn; cap respected.

### Operator check-ins (`operator.progress_request`)

Every five minutes, Aiur publishes `operator.progress_request` to each active agent's event subscription. You see it as one event line in the digest the next time your turn boundary drains — exactly like a firehose comment, never mid-tool-call.

When you see it, reply with a single `emit_event` call:

```
emit_event(name: "progress.checkin", payload: %{
  percent: <N * 10>,
  label: "<phase>: <what you're doing now>, <tail you're budgeting>"
})
```

Rules:

- `percent` is your **current** 1-of-10 estimate, expressed as `N * 10` (so a "6 out of 10" sends `percent: 60`).
- Your check-in **trumps** any prior phase guess, even when it lowers the bar. The renderer treats the check-in as the new floor.
- Do not change your work plan, do not ask the operator anything, do not narrate the ping in chat. It's a silent status request.
- One check-in per request — don't fan out multiple. If two requests arrived in the same digest, reply to the most recent.
- After replying, continue whatever you were doing.

### Tooling environment

Aiur pre-configures `HEX_HOME`, `MIX_HOME`, and `MISE_TRUSTED_CONFIG_PATHS` for you, pointing at per-workspace directories. `mise trust` has already been run for the workspace's `mise.toml`. Run `mix` and `mise exec -- mix ...` directly — do not prefix commands with `HEX_HOME=/tmp/...` or `MISE_TRUSTED_CONFIG_PATHS=...`. Inventing your own paths bypasses the pre-warmed Hex cache and forces a re-fetch of every dependency.

### Dev loop

Branch off the latest `main` and run this loop:

1. Implement
2. Add / update / run tests
3. Build
4. Lint (with autofix)
5. Commit using short, 3–7 word messages
6. Push
7. **Open the PR as a draft** (not ready for review yet)
8. **Self-review the draft PR with `ce-code-review`** against the diff you just pushed
9. Implement any issues `ce-code-review` surfaces (commit + push the fixes)
10. If you still believe the work is complete and correct, **mark the PR ready for review** and add the `agent:human-review` label

Do **not** self-merge. Always await user review after marking the PR ready.

**When you flip the label to `agent:human-review`, your turn loop ends naturally.** Do not keep polling `gh pr view` / `gh issue view` waiting for review comments — that wastes turns. Aiur will resume you when the label flips back to `agent:in-progress` (for rework) or `merging`. If you have nothing left to do on the current turn but the label is still `agent:in-progress` (e.g., you're blocked on an upstream PR merging), emit `pause.request` instead of looping; the operator will see the ❗ and reply when ready.

### Manual CLI verification before opening a PR

Before opening the draft PR, run the CLI locally and manually exercise all new functionality end-to-end. If the CLI fails to run, debug and fix the issues — do not skip verification or give up. Only open the draft PR once the requested functionality is confirmed working in the CLI.

### Closing keyword in PR description

Every PR description must start with `Closes #N` (or `Fixes` / `Resolves`) for the originating issue so GitHub auto-closes it on merge. Multiple issues: `Closes #43, #46`.

### Out-of-scope findings

While working on an issue, if you find a separate, real problem that is **not** required to ship the current task, do not silently fix it inside the same PR. Instead:

1. Open a new GitHub issue describing the finding (clear title, evidence, suggested fix if obvious).
2. Label the new issue `needs-triage` so the user triages it before any agent picks it up.
3. Reference the issue you're currently working on inside the new issue (e.g., "surfaced while working on #N").
4. Add a comment on your current issue with a link to the new issue (e.g., "out-of-scope finding filed as #M").

Keep the current PR focused on the originally-scoped change.

### Complexity routing

When a GitHub issue has one of `complexity:1` through `complexity:5` as a label, use it as the portable baseline signal for model choice, agent choice, and Compound Engineering skill flow. **Treat the label as a starting hypothesis, and the skills below as suggestions, not mandates.** The issue creator wrote the label before reading the code — once you've read the issue, the linked context, and the actual implementation surface, you almost always have more information than they did. If your read of the work disagrees with the label, adjust freely: drop steps that are overhead for what you're actually shipping, add steps the label undersold. Document the disagreement in the PR routing note so the next reader sees why.

If the issue has no complexity label, treat it as `complexity:3` until evidence says otherwise. Existing workflows without complexity labels should continue normally; do not block or fail just because the label is absent.

GitHub Projects numeric fields such as `points` or `complexity` may become a secondary signal in some repositories, but label-based complexity is the default because labels work on ordinary GitHub issues without Projects setup.

#### `complexity:1` — trivial, one-shot

A rename, a copy tweak, a config bump, a single-file bug fix with an already-understood cause. Roughly under 30 minutes; no architectural decisions.

- Suggested model: Codex.
- Suggested skills: `ce-work` only.
- Usually skip: `ce-brainstorm`, `ce-plan`, `ce-doc-review`, full `ce-code-review`. A self-read of the diff before pushing is enough.

#### `complexity:2` — small, contained

A bounded bug fix or a small feature addition that lives inside one subsystem and extends existing tests. Roughly an hour or two.

- Suggested model: Codex.
- Suggested skills: `ce-work`, then `ce-code-review` on the diff before opening the PR for review.
- Usually skip: `ce-brainstorm`, `ce-plan`, `ce-doc-review`. Mental sequencing is enough — no plan document.

#### `complexity:3` — moderate, multi-file

Multiple files, real sequencing decisions, but contained to one subsystem. Roughly half a day. Default for unlabelled issues.

- Suggested model: Codex by default. Switch to Claude when the work touches concurrency, persistence, or any path where a wrong call is expensive to roll back.
- Suggested skills: `ce-plan` (short — 1-2 implementation units) → `ce-work` → `ce-code-review`.
- Usually skip: `ce-brainstorm` if scope is already clear from the issue. `ce-doc-review` optional — run it only if the plan touches more than one subsystem.

#### `complexity:4` — cross-cutting, design decisions

Touches multiple subsystems or introduces a new abstraction. Has design decisions other agents and contributors will live with. A day or more.

- Suggested model: **the latest Claude model** (don't pin to an older version unless the user explicitly says so).
- Suggested skills: `ce-plan` (full plan: implementation units, test scenarios, risk section) → `ce-doc-review` on the plan → `ce-work` → `ce-code-review`.
- Optional: `ce-brainstorm` first if the issue is exploratory or scope is unclear.
- Treat the plan as a review artifact — push the plan, link it from the issue, give the user a chance to redirect before implementation starts.

#### `complexity:5` — strategic, high-stakes

New architecture, multi-system change, security/auth, data-integrity, anything where "wrong" means an incident. Multi-day work.

- Suggested model: **the latest Claude model** with `model_reasoning_effort=high`. Don't downgrade to a smaller or older model at this tier — the depth of reasoning matters more than the speed.
- Suggested skills: `ce-brainstorm` → requirements doc → `ce-doc-review` on the requirements → revise → `ce-plan` → deepen the plan → `ce-doc-review` on the plan → revise → `ce-work` → `ce-code-review`.
- Strongly suggested: request adversarial review on the diff by naming the relevant persona explicitly — `ce-security-reviewer`, `ce-data-migration-expert`, `ce-architecture-strategist`, `ce-adversarial-reviewer`. Default checks alone are usually not enough at this tier.
- Land in small, reviewable commits; never one mega-PR.

### Complexity routing note in PR descriptions

Every PR description must include a `### Complexity routing` block that answers four things in a few lines:

1. **Signal** — the complexity label on the issue (or `untagged → treated as complexity:3`).
2. **Skills used** — the skill/agent/model path you actually ran.
3. **Rationale** — why those choices fit *this* issue, not just the label.
4. **Adjustment** — whether you followed the recommended path or moved up/down, and why.

Example:

```markdown
### Complexity routing

- Signal: `complexity:3`
- Skills used: `ce-plan` → `ce-work` → `ce-code-review`
- Rationale: Two files, one subsystem, but the new code path touches the
  SessionWriter callback chain — used Claude instead of Codex so the
  failure-mode analysis stayed sharp.
- Adjustment: Stayed on the complexity:3 recommended path; the SessionWriter
  touch was inside scope and didn't warrant escalating to 4.
```

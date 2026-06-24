---
name: aiur-loop
description: "Use when running the aiur self-improvement loop — driving aiur Codex agents to clear the stability backlog into merged PRs, code-reviewing agent PRs and commenting so they rework, periodically rebuilding aiur on latest main, and resuming across sessions via /goal. Triggers: 'run the aiur loop', 'improve aiur with aiur', 'keep going until all tickets are merged', 'clear the agent:todo backlog', or a /goal handoff continuing a stability run."
---

# Run the aiur self-improvement loop

Drive aiur to improve itself: aiur Codex agents work `agent:todo` tickets into PRs while you
(the operator's strongest model) triage, review, merge, and harden — rebuilding aiur on its own
merged fixes as you go. This skill owns the high-level loop.

**REQUIRED SUB-SKILL:** use `aiur-run` for launch/lifecycle (pre-flight, build, prewarm, detach,
pause/resume/stop) and `aiur-status` for the per-agent status read. Do not duplicate those here.

## Roles

- **aiur Codex agents** work the `agent:todo` stability batch — small, well-scoped fixes.
- **You** triage/tag the backlog, CE-code-review every PR, and take a ticket yourself (CE
  brainstorm→plan→work→review, or debug-first for an existing bug; TDD; 3–7 word commits; no
  AI/Claude mention; push; merge) **only** when an agent gets stuck or the fix is complex +
  important. Salvage validated-but-unpushed work into PRs rather than re-running an agent on it.
- **Stability first.** File new issues only for genuine stability/correctness bugs surfaced
  during the run — do not over-optimize. Pause non-stability work (`agent:todo` removed).

## The loop

1. **Run** aiur on a couple of `agent:todo` tickets (`aiur-run`). Confirm a clean slate first:
   no `beam.smp` (`pgrep -lf beam.smp`), port 4000 free, `epmd -names` empty. A stale BEAM will
   grab newly-`agent:todo` tickets on OLD code — always reap it first.
2. **Monitor** live (`/loop 2m /aiur-status`) for bugs, snags, stuck agents, CPU/FD. File focused
   `agent:todo` issues for real stability problems, each with repro + acceptance criteria.
3. **Let agents finish** their turns and open PRs.
4. **Code-review each PR** (Compound Engineering / `/code-review`). Leave the findings as a
   **comment on the linked ticket** (not only the PR) so the agent ingests them as rework. The
   first couple of times, **verify the comment→rework loop actually fires** — watch the issue flip
   to `agent:rework` and the agent push a commit addressing your comment. If it doesn't fire, the
   loop is broken: file it and fall back to fixing inline.
5. **Merge when ready** (CI green, review addressed), then **prove the fix in the running aiur**
   (below).

**Periodically** — after a couple of tickets land, or on a time cadence — **pull main, stop aiur,
rebuild on latest, and rerun** on the remaining/new `agent:todo` tickets:

```
git -C <repo> pull origin main && aiurdev stop && aiurdev build && aiurdev --bg --debug
```

Each merge changes the code agents run; rebuilding is how the loop dogfoods its own fixes. Tag
the next batch `agent:todo` and watch specifically for the behavior the just-merged fixes changed.

## Prewarm freshness — check every rebuild (#567)

Agents branch off a **warm base** at `~/.aiur/repo/<owner>/<name>`, NOT your checkout. It can go
stale (`prewarm.poll_seconds: 0` disables the background fetch; materialize doesn't re-fetch).
After any merge advances main:

```
git -C ~/.aiur/repo/<owner>/<repo> rev-parse HEAD     # must equal:
git ls-remote <remote> refs/heads/main
```

If the base lags live main, new agents are silently working old code — stop, restore freshness
(ensure `prewarm.poll_seconds` > 0, or force a base rebuild), then relaunch.

## CPU & concurrency ramp

This box's stable ceiling is ~3 concurrent agents — 5+ melts it (ref #465). Start at 3, then tune:

- **Watch** CPU/load (`top`/`ps`) and `grep -i emfile <log>` (#409 — FD exhaustion at high concurrency).
- **Ramp UP** `agent.max_concurrent_agents` (and `pre_warmed_sessions` to match, #376) by 1 when
  load stays healthy and the box has clear headroom — the goal is more parallelism as it becomes safe.
- **Ramp DOWN** immediately if CPU pegs, `:emfile` appears, or turn quality/stability erodes.

## Prove each fix

After merging + rebuilding, demonstrate the fix actually changed live behavior — don't trust green
CI alone. E.g. reaper fix → plant a stale BEAM and confirm it's reaped; prewarm fix → confirm a
fresh workspace's branch base includes the latest merge; crash fix → exercise the path that used to
crash. Record the proof in the ticket and `HANDOFF.md`.

## Write a /goal to resume — don't stop until done

The loop must survive context limits and session breaks. When pausing or low on context, **write a
2-sentence `/goal`** capturing (a) the remaining tickets + their state and (b) the standing intent:
*keep running the loop until every targeted ticket is implemented, reviewed, merged, and proven, and
aiur is confirmed still stable.* Then **tell the user to paste it back via `/goal`** to continue the
run. Update `HANDOFF.md` alongside it. Do not declare the run done until the backlog is empty and
aiur is verified stable.

## Known issues to watch

- **#567** — prewarm warm-base can serve stale main; verify base == origin/main after every merge.
- **#409** — FD / `:emfile` at high concurrency; keep agent count in check.
- **#376** — `pre_warmed_sessions` hard-caps live agents; raise it with `max_concurrent_agents`.
- **#465** — agent-count ramp/throttle; box ceiling ~3.
- **#438** — control rpc can mask real errors as "no running node"; cross-check `aiurdev status`.
- Agents validate via unit/integration tests only — manual `aiurdev --test` is fail-closed (#555).
  Don't reject a PR for skipping manual smoke; check test coverage instead.

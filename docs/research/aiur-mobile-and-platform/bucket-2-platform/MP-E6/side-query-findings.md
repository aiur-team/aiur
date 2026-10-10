# MP-E6-C10-T03 — Side-query spike findings

Run 2026-10-10 on one host. Claude Code 2.1.296 (`--model sonnet --effort low`), codex-cli
0.160.0 (app-server over stdio). Test parents only; no live agent was touched. 15 forked
queries used of the 60 budgeted (11 Claude, 4 Codex). Scripts were throwaway and are not
committed. Anything not listed as measured is **unverified**.

**Follow-up run (MP-E6-C10-T03b, same day, same host and versions):** 41 more forked queries
(32 Claude, 9 Codex), 56 of 60 used in total. Its results are in
[Follow-up results](#follow-up-results-mp-e6-c10-t03b). It **corrects the SQ-5 cost figures
below**: they include the parent session's own accumulated cost.

## Results

| SQ | Result | Method | Runs |
| --- | --- | --- | --- |
| SQ-1 isolation (Claude) | **Pass.** Parent jsonl md5 identical before/after 4 forks (idle parent) and 5 forks (360k parent); worktree `git status` + `svc.py` hash unchanged. Fork answered from parent memory ("I never checked that callers really retry" was a statement made only in the parent's turn). Each fork writes its own new session jsonl. | `claude -p --resume <id> --fork-session --permission-mode plan --allowedTools=Read,Grep,Glob --disallowedTools "Bash Edit Write"` | 9 |
| SQ-3 read-only (Claude) | **Pass.** Asked to append to `svc.py` and `touch pwned`: refused, no change, no `pwned`. Costly (35k fresh cache write, 8 s) because plan mode makes the model try to write a plan file. | same flags + write prompt | 1 |
| SQ-6 mid-turn (Claude) | **Pass with a caveat.** Forked 15 s into a parent turn running `sleep 45`: both finished, parent printed `parent-done`, 0 unparseable jsonl lines, last line parsed at fork time. Caveat: the fork saw the in-flight tool call as stopped and answered "the parent session is idle" — the answer must not be read as parent state. | background parent + fork | 1 |
| SQ-2 speed (Claude) | **Pass at ~45k context** (below). **Pass at ~360k warm** (below). The ticket's 150k point was not hit: the filler tokenised at about 360k, not 150k. Cold cache measured only by the first big fork. | see table | 3 + 5 + 1 |
| SQ-5 cost (Claude) | **Superseded — these figures include the parent's cost; see the follow-up.** ~USD 0.17/query at ~45k warm (pass, ≤ 0.25). **~USD 1.59/query at ~360k warm; 2.94 cold** — fails the 0.25 line by 6x. 150k not measured; do not interpolate. Figures are the harness's `total_cost_usd`. | `--output-format json` | as above |
| SQ-4 Codex | **Fork exists and is read-only in practice; context inheritance not proven.** `thread/fork` with `ephemeral: true` is rejected unless `excludeTurns: true` is also set (`-32600 ephemeral paginated thread/fork requires excludeTurns: true`). With both, fork turns answered in 2.3–3.2 s total (first token 1.3–2.9 s); a write attempt under `readOnly` was refused ("filesystem is read-only"); no rollout file under `~/.codex/sessions` changed and no new one appeared. Confound: the parent's fact was also written in a comment in `svc.py`, which the fork could read — so these runs do not show the fork saw parent turns. **Settled in the follow-up: the fork inherits history.** | app-server JSON-RPC: `thread/start`, `turn/start`, `thread/fork`, `turn/start` | 4 |
| SQ-7, SQ-8 | Not run here. Follow-up: SQ-8 run; SQ-7 still **unverified**. | | 0 |
| Mid-turn Codex parent, `/talk` parent shapes (Claude and Codex) | Not run here; run in the follow-up. | | 0 |
| `aiur-claude` `forkSession` (cross-repo) | Not checked here; source read in the follow-up, not run. | | 0 |

### SQ-2 / SQ-5 detail (Claude, low effort, `duration_ms` from the harness JSON)

The cost column is the harness total and includes the parent's cost; the follow-up has the
per-fork figures.

| Parent context | Cache | `duration_ms` | cost USD | cache read / created |
| --- | --- | --- | --- | --- |
| ~45k | warm | 2.6 / 3.5 / 3.5 s | 0.166 / 0.167 / 0.168 | 41.6k / 3.7k |
| ~45k | cold (first fork) | 3.6 s | 0.329 | 0 / 45k |
| ~360k | warm | 2.2–2.4 s (4 runs) | 1.585 | 357k / 3.7k |
| ~360k | cold-ish (first fork) | 18.9 s | 2.942 | 9k / 352k |

The harness also reports `duration_api_ms` of 33–50 s on the large fork; I did not
reconcile it with `duration_ms`, so treat the latency figures as `duration_ms` only.
Median warm answer is under 4 s at both sizes, well inside the 15 s line. A fork never reuses
less than ~all of the parent's cache when it is warm, so cost is dominated by cache-read
price times parent size, and the first fork after the cache expires pays a full rewrite.

## Follow-up results (MP-E6-C10-T03b)

Run 2026-10-10, same host and versions (Claude Code 2.1.296 `--model sonnet --effort low`;
codex-cli 0.160.0 app-server, model `gpt-6-luna`, effort low). Test parents only.

| SQ | Result | Method | Runs |
| --- | --- | --- | --- |
| SQ-5 correction (Claude) | **The harness `total_cost_usd` of a `--resume --fork-session` run includes everything the parent session spent before the fork.** `modelUsage` token totals equal the parent's totals plus the fork's one call exactly (150k parent: 294,811 + 9,216 = 304,027 cache-read tokens), and `duration_api_ms` is cumulative in the same way, which explains the 33–50 s the first run could not reconcile. Per-fork cost is the fork's total minus the parent's last total. | arithmetic on the saved result JSON of the first run and of this one; 5 forks repeating one question under different flag sets all showed the same parent-inclusive totals | 5 |
| SQ-2 / SQ-5 at 150k (Claude) | Parent measured at **157.8k tokens**. Repeating one question: first fork 8.9 s, USD 0.596; next five 3.3–4.9 s, USD 0.031 each. Parent jsonl md5 unchanged. See the cache finding below before using the USD 0.031 figure. | `mk` filler of 2 × 1,300 lines; flags of the first run | 6 |
| Cache reuse (Claude) | **`--disallowedTools` makes every new question a full cache write.** Removing tools changes the request prefix, so the fork cannot read the parent's cache, and a later fork only hits if it repeats the same question. The first run's "warm" rows repeated one question, so they do not describe real use. Without `--disallowedTools` the fork reads the parent's own cache when the parent was active inside the cache lifetime. | parent takes one turn of its own, then forks with a different question each | 7 |
| SQ-3 without tool removal (Claude) | **Permission-only: pass.** `--allowedTools=Read,Grep,Glob` alone, asked to edit and `touch pwned`: harness reported `permission_denials: [Edit, Bash]`, worktree and parent unchanged. Not tested against a user settings file that allows Bash commands; that would let them run. **Plan mode without `--disallowedTools`: no write, but not proven enforced** — the model declined without attempting a tool call (no denial recorded) and wrote a plan file under `~/.claude/plans/`. | write prompt under each flag set | 2 |
| SQ-4 Codex context | **The fork inherits parent history.** A fact stated only in a parent turn (in no file) was returned by an `ephemeral: true, excludeTurns: true` fork, a persistent `excludeTurns: false` fork and a persistent `excludeTurns: true` fork. Fork input was 17,740 tokens against the parent's 15,350. `excludeTurns` only controls whether `thread.turns` is filled in the response (1 turn vs 0). `ephemeral: true` with `excludeTurns: false` is still rejected. Persistent forks each wrote a new rollout file; the ephemeral one wrote none; the parent's rollout md5 did not change. Total 1.9–5.2 s, first token 1.7–5.0 s. | app-server JSON-RPC, as in the first run | 3 (+3, see note) |
| Mid-turn Codex parent | **Pass.** Forked 10 s into a parent turn running `sleep 40`, no `lastTurnId`: fork answered in 2.2–2.3 s with the parent-only fact; the parent finished and replied `parent-done` (42–45 s) and still knew the fact afterwards. One of the two forks described the parent's request as "interrupted". | same, fork during a running turn | 2 |
| `/talk` parent shape, Claude | **Pass, with the SQ-6 caveat.** Interactive Claude Code session (tmux, not `-p`) with a background shell running, forked while between two edits of one turn. Fork answered the parent-only fact (5.5 s, USD 0.208, first fork so a full cache write; second 4.1 s, USD 0.025). Parent jsonl gained no fork content and had 0 unparseable lines; the parent finished both edits. Both forks said the wait "was cut off" and the background shell "was stopped": both were still running. `--no-session-persistence` left no fork session file (the plain fork left one). | `claude -p --resume <id> --fork-session` from another process | 2 |
| `/talk` parent shape, Codex | **Pass.** Interactive `codex` TUI thread forked from a **separate** `codex app-server` process while the TUI was between two edits: answered the parent-only fact in 2.5 s (18,310 input tokens, 11,008 cached); the TUI's rollout file gained no line and no fork content; the TUI finished both edits. The fork said the parent "was interrupted during the wait"; it was not. | `thread/fork` by thread id read from the TUI's rollout file | 1 |
| SQ-8 replay vs native fork (Claude) | **Agreement 16 of 20, but the test did not exercise truncation.** 10 "why" questions on one 7-turn parent (5 reasons given by the operator, 5 the agent's own). Replay stated the same reason as the fork on all 10. I scored 4 answers 1 instead of 2 because they opened with "not in the summary" and then gave the right reason. The parent had only 36 transcript entries, so "the last 40" was the whole session; quality when entries fall outside the window is **unverified**. Replay 1.9–2.7 s and USD 0.133 per question (a fresh session writes its ~45k-token prompt, mostly the harness base prompt, each time); fork 2.1–3.5 s and USD 0.146–0.148 with `--disallowedTools`. | fork with the first run's flags; replay = 3-line briefing + entries with tool input/output cut to 300 chars + question, fresh `claude -p`, read-only tools | 10 forks + 10 replays |
| SQ-7 `history_copy` | **Unverified — not run.** No OpenAI-compatible provider key was available in the agent environment. | | 0 |
| `aiur-claude` `forkSession` (cross-repo) | **Present, not usable as a side query as written; read, not run.** `aiur-claude` 1.1.0 (local checkout at `b1ea979`) already has `thread/fork`: the forked thread's first turn runs `--resume <source session> --fork-session`. It copies the source thread's permission mode and dynamic tools, has no read-only or no-persistence option, and only forks a thread held in the same server process. Aiur does not call it (`rg 'thread/fork' src/lib` finds nothing). | source read of `src/server.ts` | 0 |
| Muse, Gemini, OpenCode forks | **Unverified — not run.** | | 0 |

Note on SQ-4: the first Codex pass asked for a "codeword … written nowhere on disk". One fork
and the parent itself answered "NONE" although the fact was in their context (same input
token counts as the forks that answered). I reworded the fact as a naming decision and reran;
the table reports the rerun. The 3 forks of the discarded pass are counted in the budget.

### Per-fork cost (Claude, parent cost removed)

| Parent context | Fork flags | Question | Cache read / created | `duration_ms` | USD per fork |
| --- | --- | --- | --- | --- | --- |
| ~45k | plan + `--disallowedTools` | first fork | 0 / 45k | 3.6 s | 0.183 |
| ~45k | plan + `--disallowedTools` | repeated | 41.6k / 3.7k | 2.6–3.5 s | 0.021 |
| ~49k | plan + `--disallowedTools` | new each time (11 runs) | 12.6k / 36.0k (1 run recorded) | 2.1–3.6 s | 0.146–0.148 |
| ~49k, parent warm | plan, no `--disallowedTools` | new | 48.6k / 1.8k | 2.9 s | 0.014 |
| ~49k, parent warm | `--allowedTools` only | new (3 runs) | 48.6k / 0.1k | 1.6–2.2 s | 0.006–0.007 |
| ~158k | plan + `--disallowedTools` | first fork | 9.2k / 148.6k | 8.9 s | 0.596 |
| ~158k | plan + `--disallowedTools` | repeated (5 runs) | 154.1k / 3.7k | 3.3–4.9 s | 0.031 |
| ~158k | plan + `--disallowedTools` | new | 11.0k / 146.8k | 4.0 s | 0.591 |
| ~158k, parent warm | plan, no `--disallowedTools` | new | 156.0k / 3.7k | 3.4 s | 0.033 |
| ~360k | plan + `--disallowedTools` | first fork | 9k / 352k | 18.9 s | 1.408 |
| ~360k | plan + `--disallowedTools` | repeated | 357k / 3.7k | 2.2–2.4 s | 0.051 |

The ~45k and ~360k rows are the first run's data with the parent's cost subtracted. A fork
that cannot read a cache pays about USD 4 per million context tokens; one that can pays about
USD 0.1–0.2 per million. Not measured: a fork without `--disallowedTools` when the parent has
been idle past the cache lifetime (expected to cost the same as the cache-miss rows), and what
the cache lifetime is.

## Verdicts against the ticket criteria

| Criterion | Verdict |
| --- | --- |
| Isolation | **Pass for Claude** (SQ-1, SQ-3, SQ-6, interactive mid-edit parent). **Pass for Codex** (writes refused, parent rollout unchanged, mid-turn and separate-process forks leave the parent running). |
| Speed | **Pass.** Every warm or cache-miss fork at ~158k answered in 3.3–4.9 s; the slowest first fork was 8.9 s at 158k and 18.9 s at 360k. Codex 1.9–5.2 s. |
| Cost | **Pass when the fork reads the parent's cache; fail above ~60k context when it cannot.** USD 0.033 at 158k with a warm parent and no `--disallowedTools`; USD 0.59 at 158k with `--disallowedTools` or (expected, not measured) an idle parent. The first run's "fails by 6x" came from counting the parent's cost. Codex reports tokens, not USD: 16–18k input per fork on a ~16k parent, 11–17k of it cached. |

## Design sketch for MP-E6-C10-T05

- **Compute fork cost as fork total minus the parent's last total.** Never show the harness
  `total_cost_usd` of a forked run as the query's cost.
- Claude: `claude -p --resume <id> --fork-session --no-session-persistence --permission-mode plan
  --allowedTools=Read,Grep,Glob -- <prompt>`. **Leave out `--disallowedTools`**: it costs a full
  cache write per question. Before shipping, prove plan mode refuses a write the model actually
  attempts, and test with a settings file that allows Bash; if either fails, keep
  `--disallowedTools` and accept the cache-miss price.
- Offer `fork_query` freely while the parent has been active inside the cache lifetime. For an
  idle parent, or if `--disallowedTools` stays, gate on context size: about USD 4 per million
  tokens, so the 0.25 line is near 60k. Otherwise fall back to the queued consult (C5-T04).
- Codex: `thread/fork` with `ephemeral: true`, `excludeTurns: true`, `sandbox: read-only`,
  `approvalPolicy: never`, then `turn/start` with `sandboxPolicy: {type: readOnly}`. It
  inherits history, works from a separate app-server process and on a mid-turn parent, and
  needs no `lastTurnId`.
- Never present a fork's description of "what the agent is doing now" as live state. Claude
  and Codex forks both reported running work as interrupted or stopped; use the briefing card.
- Replay fallback: tell the fresh session to answer directly; an "if the entries do not say"
  escape clause made 4 of 10 correct answers open with "not in the summary".
- `aiur-claude`: its `thread/fork` needs a read-only, non-persistent variant before the
  headless Claude harness can move from replay to native.

## Still unverified before C10-T05 / C13-T07

1. SQ-7 `history_copy` time and cost (needs an OpenAI-compatible provider key).
2. SQ-8 on a parent with more than 40 transcript entries, which decides E6-OQ21 for Muse and
   Gemini.
3. Plan mode as hard enforcement without `--disallowedTools`, and permission-only forks under
   a settings file that allows Bash.
4. Fork cost for a parent idle past the cache lifetime, and the lifetime itself.
5. A session that actually ran `/talk` (the skill and `talk serve` do not exist yet; the
   parents here were interactive, mid-edit sessions with a background shell).
6. `aiur-claude` `thread/fork` run end to end; Muse, Gemini and OpenCode forks.

# MP-E6-C10-T03 — Side-query spike findings

Run 2026-10-10 on one host. Claude Code 2.1.296 (`--model sonnet --effort low`), codex-cli
0.160.0 (app-server over stdio). Test parents only; no live agent was touched. 15 forked
queries used of the 60 budgeted (11 Claude, 4 Codex). Scripts were throwaway and are not
committed. Anything not listed as measured is **unverified**.

## Results

| SQ | Result | Method | Runs |
| --- | --- | --- | --- |
| SQ-1 isolation (Claude) | **Pass.** Parent jsonl md5 identical before/after 4 forks (idle parent) and 5 forks (360k parent); worktree `git status` + `svc.py` hash unchanged. Fork answered from parent memory ("I never checked that callers really retry" was a statement made only in the parent's turn). Each fork writes its own new session jsonl. | `claude -p --resume <id> --fork-session --permission-mode plan --allowedTools=Read,Grep,Glob --disallowedTools "Bash Edit Write"` | 9 |
| SQ-3 read-only (Claude) | **Pass.** Asked to append to `svc.py` and `touch pwned`: refused, no change, no `pwned`. Costly (35k fresh cache write, 8 s) because plan mode makes the model try to write a plan file. | same flags + write prompt | 1 |
| SQ-6 mid-turn (Claude) | **Pass with a caveat.** Forked 15 s into a parent turn running `sleep 45`: both finished, parent printed `parent-done`, 0 unparseable jsonl lines, last line parsed at fork time. Caveat: the fork saw the in-flight tool call as stopped and answered "the parent session is idle" — the answer must not be read as parent state. | background parent + fork | 1 |
| SQ-2 speed (Claude) | **Pass at ~45k context** (below). **Pass at ~360k warm** (below). The ticket's 150k point was not hit: the filler tokenised at about 360k, not 150k. Cold cache measured only by the first big fork. | see table | 3 + 5 + 1 |
| SQ-5 cost (Claude) | ~USD 0.17/query at ~45k warm (pass, ≤ 0.25). **~USD 1.59/query at ~360k warm; 2.94 cold** — fails the 0.25 line by 6x. 150k not measured; do not interpolate. Figures are the harness's `total_cost_usd`. | `--output-format json` | as above |
| SQ-4 Codex | **Fork exists and is read-only in practice; context inheritance not proven.** `thread/fork` with `ephemeral: true` is rejected unless `excludeTurns: true` is also set (`-32600 ephemeral paginated thread/fork requires excludeTurns: true`). With both, fork turns answered in 2.3–3.2 s total (first token 1.3–2.9 s); a write attempt under `readOnly` was refused ("filesystem is read-only"); no rollout file under `~/.codex/sessions` changed and no new one appeared. Confound: the parent's fact was also written in a comment in `svc.py`, which the fork could read — so these runs do not show the fork saw parent turns. | app-server JSON-RPC: `thread/start`, `turn/start`, `thread/fork`, `turn/start` | 4 |
| SQ-7, SQ-8 | **Unverified — not run.** | | 0 |
| Mid-turn Codex parent, `/talk` parent shapes (Claude and Codex) | **Unverified — not run.** | | 0 |
| `aiur-claude` `forkSession` (cross-repo) | **Unverified — not checked.** | | 0 |

### SQ-2 / SQ-5 detail (Claude, low effort, `duration_ms` from the harness JSON)

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

## Verdicts against the ticket criteria

| Criterion | Verdict |
| --- | --- |
| Isolation | **Pass for Claude** (SQ-1, SQ-3, SQ-6). **Codex: pass on writes, inconclusive on context** (SQ-4). |
| Speed | **Pass** (warm median ≤ 4 s). Cold first fork at 360k took 19 s: expect "about 20 seconds" after idle periods over the cache TTL. |
| Cost | **Fails above small contexts.** Inside 0.25 only around 45k. Owner decides (E6-OQ15); contexts of agents in real runs are likely well above 45k. |

## Design sketch for MP-E6-C10-T05

- Offer `fork_query` only when the parent's context size (from harness usage) is under a
  configured token ceiling or the owner accepted per-query cost; otherwise fall back to the
  queued consult (C5-T04).
- Claude: use the flags above, and pass the prompt after `--` because `--allowedTools` is
  variadic and swallows a trailing prompt. Drop `--permission-mode plan` and rely on
  `--allowedTools`/`--disallowedTools` if the plan-file detour (SQ-3) costs too much; that
  alternative was not tested.
- Codex: `thread/fork` with `ephemeral: true`, `excludeTurns: true`, `sandbox: read-only`,
  `approvalPolicy: never`, then `turn/start` with `sandboxPolicy: {type: readOnly}`.
  Before building on it, run the follow-up below.
- Never present a mid-turn fork's description of "what the agent is doing now" as live state
  (SQ-6 caveat); use the briefing card for that.
- Warn that the first fork after idle pays a cache rewrite (cost and latency).

## Follow-ups needed before C10-T05 / C13-T07

1. Codex SQ-4 with a fact that exists only in the parent's turns (not in any file), and with
   `excludeTurns` both true and false, to settle whether the fork inherits history.
2. A 150k-context Claude parent (this run overshot to ~360k) for the real cost point.
3. SQ-7, SQ-8, the `/talk` parent shapes, mid-turn Codex, and the `aiur-claude` check.

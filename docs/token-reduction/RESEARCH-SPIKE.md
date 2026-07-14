# Token-Usage Reduction — Research Spike

> **Status:** living document. **Part 1** below (the four-tool program + first-pass
> optimization angles) is complete and adversarially verified. **Part 2 — additional
> "new options"** (provider pricing tiers, prompt compression, response/tool-result
> caching, deterministic pre-computation, cross-agent memory, rework economics, frontier
> techniques) is pending a running research pass and will be appended.

**Scope:** the 4-tool program (ccusage, Serena, context-mode, caveman) **plus** other
optimization angles, evaluated against our *actual* fleet. Two adversarially-verified
multi-agent workflows (25 agents, ~1.06M tokens, 0 errors). Claims below are tagged
**[verified]** (adversarial pass held), **[corrected]** (pass changed it), or
**[measure]** (only ccusage can settle it).

## TL;DR

1. **ccusage — adopt (with caveats).** Genuinely first-class Codex support, verified on
   our host. It's the measurement backbone; everything else gates on it.
2. **The three "reducers" are all weaker on OUR stack than advertised**, and their
   priority is inverted from the original ask:
   - **caveman → SKIP.** [verified] Independent JetBrains 82-task benchmark: **8.5%**
     real output savings, not the marketed 65% — minus ~1–1.5k input tokens/turn of
     injected rules, on our *already-terse* 3–7-word commits ≈ break-even or negative.
     Plus a real fidelity hazard to the structured payloads our Executor parses.
     **Decision: dropped from the program.**
   - **Serena → narrow, capped trial only** (not fleet-wide). 99% of our code is Elixir,
     which is Serena's **weakest** LSP tier (immature Expert backend); Codex doesn't pool
     MCP, so 16 agents = up to 16 heavy language-server processes on a load-gated host.
   - **context-mode → trial, gated on proving hooks even fire under `codex app-server`.**
     All its docs assume the *interactive* Codex CLI; tool-input rewriting (its core
     mechanism) is unsupported on Codex; it overlaps a spill mechanism we already have.
3. **The biggest lever isn't in the four tools — it's reasoning tokens** (config-only),
   but the ROI is smaller than the internet claims **and** there's a config/runtime
   discrepancy to resolve first (below).

## Our fleet (verified from the repo)

| Fact | Detail | Why it matters |
|---|---|---|
| Provider | 100% Codex, `codex app-server`, `gpt-5.6-sol` | Claude-only tools/plugins don't reach workers |
| Reasoning effort | config routes all tiers 1–5 → `…:max` **but logs show `high` emitted** | discrepancy to resolve; `max` may be invalid |
| Concurrency | up to 16 agents, one **host-global `~/.codex`** (never overridden) | MCP/plugin config hits all 16 at once; no per-ticket toggle → the kill switch is add/remove the config block |
| Language mix | **~99% Elixir (198,777 LOC / 929 files)**, <1% TS (marketing site only) | decisive against Serena's value prop |
| Prompt model | turn 1 renders full prompt; turns 2–12 append ~10 lines to the **same codex thread** | prefix caching already works; "re-render busts cache" premise is FALSE |
| Existing spill | aiur already spills big tool output to `.aiur-runtime/tool-results/` | overlaps context-mode |
| Governance | **no** rules anywhere about MCP/plugins/external CLIs/token budgets | blank slate — add steering in `.aiur/prompt.md` (no rebuild) |
| Quota | `model-usage.json`: 8/100 weekly used (~92% headroom) | this is cost-efficiency, not an exhaustion fire |

## Per-tool verdicts

### ccusage — **adopt-with-caveats**
- First-class Codex support **[verified]**: `ccusage codex daily|monthly|session`,
  reads `~/.codex` rollout JSONL `token_count` events (input/cached/output/**reasoning**).
- Caveats: known Codex double-count bugs — the more dangerous ones are **#897** (forked
  sessions ~3.4×) and **#950** (subagent `thread_spawn` replay up to **91×**), not the
  #884/#988 first flagged (all fixed as of mid-2026, but the parser is still "experimental").
  → Pin a current version and **spot-check `ccusage codex daily` against Codex `/status`**
  before trusting absolute numbers. It's snake_case `token_count` on disk. Run per
  `CODEX_HOME`/user (both `orangekid` and `applekid` launch agents). Complements
  `model-usage.json` (quota %, not tokens); no per-ticket attribution without a timestamp join.

### caveman — **SKIP** (evidence is decisive)
- Real net **8.5%** output reduction on an independent 82-task agentic benchmark, quality
  unaffected (p=0.82) **[verified]** — the 65% headline is chat-prose-only. Maintainer's own
  `HONEST-NUMBERS.md` concedes ~1–1.5k input tokens/turn overhead and "below zero on terse
  workloads." Our commits are already 3–7 words.
- Fidelity hazard specific to us: it steers the agent's prose, which risks the
  **Executor-parsed** `emit_event`/`progress`/`checkin` payloads and Agent Workpad headings
  the resume path keys on; `caveman-compress` (#112) has silently rewritten inline
  commands/env vars while reporting "validation passed."
- Codex delivery is also broken (#92 skill won't load, app-server untested).

### Serena — **trial narrowly; do NOT adopt fleet-wide**
- Decisive constraint: **99% Elixir on Serena's weakest tier.** Elixir runs via the
  **Expert** LSP (not ElixirLS/NextLS) which is immature — the migration issue is still
  **open**, and there's a just-patched deadlock for **mix.exs in a subdirectory** = our
  exact `src/`-nested layout **[corrected: directionally real, but pin+smoke-test the
  installed version]**. Elixir metaprogramming breaks find-references/definition, so grep
  is often *more* reliable — undercutting the whole token-saving premise.
- Concurrency: Codex doesn't pool MCP (#12333, closed "by design") **[verified]**; shared
  pooling only works if all agents share one project dir — ours are isolated workspaces, so
  it doesn't apply → up to 16 Serena+Expert processes (a real 23-proc/5.3 GB case) on a host
  already gated at `max_load 5.5` / `min_free_mem 3072 MB`.
- Its strong tier (TS) is <1% of the repo (marketing site).
- If trialed: install `uv` (absent) + Expert into mise, **smoke-test Expert against `src/`
  first**, cap Serena-enabled agents to 2–4, keep the config block removable as the kill
  switch, don't bake into prewarm. If xrefs are unreliable → scope to the TS site or skip.

### context-mode — **trial, gated on an app-server hook proof**
- Biggest *generic* input lever IF it works (mix test / credo / dialyzer / log tails).
- But **all install docs assume the interactive `codex` CLI**; we run `codex app-server`,
  and nothing confirms hooks register there. Tool-**input** rewriting (its core mechanism)
  is **unsupported on Codex** — `PreToolUse` returns "unsupported updatedInput", tracked to
  the still-open **#18491** **[verified — this is the load-bearing constraint]**. (Two side
  claims were **[corrected]**: Codex *does* have a `UserPromptSubmit` hook, and app-server
  isn't wholly undocumented.)
- Overlaps our native `.aiur-runtime/tool-results/` spill — reconcile first or double-spill.
  Store must sit in a sandbox writableRoot (`/tmp` or workspace) and is wiped by `before_run`.
- Gate: on ONE agent, set `[features] hooks=true`, register hooks, and **observe a >5KB output
  actually getting intercepted under `codex app-server`** before counting any savings.
  Validate only via ccusage (its own ctx-stats is unreliable, #950).

## Compatibility matrix

| Pair | Verdict | Note |
|---|---|---|
| ccusage × all three | **synergistic** | only trustworthy before/after signal; enables one-at-a-time |
| context-mode × caveman | neutral | opposite ends (input vs output); additive |
| Serena × caveman | neutral | orthogonal (input symbols vs output prose) |
| Serena × context-mode | **conflict** | context-mode would funnel Serena's precise symbol output through lossy FTS5 |
| caveman × structured output | **conflict** | risks Executor-parsed emit_event/Workpad/commit payloads |
| any two reducers at once | **conflict** | confounds ccusage attribution + stacks per-turn overhead → **strict one-at-a-time** |

## Bigger levers beyond the four tools (first-pass "other angles")

Ranked by impact × effort × fit. **These target reasoning/output tokens — a different,
larger cost line than the four tools (which are input/context-side).**

1. **Reasoning-effort tiering by complexity — config-only, highest leverage, but do the
   homework first.** Two adversarial corrections matter:
   - Community "8–15× (xhigh) / 3–5× (high)" multipliers are **2–5× overstated**; the only
     real measured data is ~**1.4× high**, ~**3× xhigh** vs medium **[corrected]**. ROI is
     real but modest — measure, don't assume.
   - `max` is **not** a documented Codex effort value (`minimal|low|medium|high|xhigh`); a
     live bug rejects `reasoning_effort=max`. **[verified]** And our logs already show we emit
     `high`, not `max` — so **first reconcile config (`sol:max`) vs runtime (`high`) and
     confirm what's actually valid** before any A/B. A failed/coerced request would corrupt
     the measurement entirely.
   - Then: keep max/xhigh on regression-sensitive tiers (4–5), trial `medium`/`high` on
     tiers 1–2, A/B one wave, watch turns-to-completion.
2. **`max_turns` 12→~8 (config-only)** — turns 8–12 re-reason the largest accumulated thread
   at top effort for the least marginal yield. Gate on ccusage showing most tickets finish <6.
3. **Cap full-suite test/perf output before it enters the thread (low effort)** — the
   `stall_timeout_ms=3.6M` bump implies some agents run full `mix test`; its output persists
   and gets re-reasoned every later turn. This is the surface context-mode targets — a wrapper
   truncating head+tail is cheaper than the MCP.
4. **universal-ctags pilot (low effort, zero LLM tokens)** — native Elixir symbol kinds since
   2018, no MCP wiring, safe at 16-way concurrency. The **cheapest Serena backstop**: agents
   grep a flat tags file instead of whole-file reads. Bake `ctags -R` into the prewarm step.
5. **Skill-surface slimming (low effort)** — worker skills loaded per workspace: using-aiur
   22 KB, aiur-agent 19 KB, **aiur-debug 45 KB**. Confirm aiur-debug isn't loaded defensively
   on non-debug turns; push low-frequency prose in `shared-agent-instructions.md` into
   on-demand skill bodies (progressive disclosure).
6. **Reasoning recompute is the real caching leak (not prefix caching).** OpenAI discards
   reasoning items between turns and Codex doesn't send `previous_response_id` (#4047), so at
   high/max effort each turn re-reasons at full price **[verified]**. ccusage's cache-hit
   ratio won't show this — look at **per-turn reasoning-token counts**. Confirms why effort
   tiering (lever #1), not a caching layer, is where the savings are.
7. **Not now:** `model_verbosity=low` (unconfirmed for our model + app-server, quality-risky
   per OpenAI's own System Card); RAG/embeddings over the codebase (grep beats it on
   actively-churning mid-size repos); sol→terra model downgrade / RouteLLM (higher regression
   risk — explicit operator decision, do config effort-tiering first).

## Recommended program (revised)

1. **ccusage first** — install host-global under each account that launches codex, capture a
   `ccusage codex daily --json` baseline, spot-check vs `/status`, wire into the Executor
   cadence. Nothing else moves until the baseline exists.
2. **Resolve the reasoning-effort discrepancy** (config `max` vs logged `high`, and whether
   `max` is valid) — this is cheap, config-only, and plausibly the highest-value single change.
3. **Then, strictly one-at-a-time with a clean ccusage window each:** context-mode (gated on
   the app-server hook proof + spill reconciliation) → Serena (capped 2–4 agents, after an
   Expert smoke test, or scoped to TS/skipped). **caveman is dropped.**
4. **Cheap parallel wins** independent of the tools: `max_turns`, test-output capping,
   ctags pilot, skill slimming.
5. **Add governance** (none exists): per-run tool steering in `.aiur/prompt.md`.

## Tracking tickets

| # | Tool | Status |
|---|---|---|
| #1171 | ccusage | open, `agent:todo`, `priority:2` |
| #1169 | Serena MCP | open, dormant (no `agent:*`) |
| #1170 | context-mode | open, dormant (no `agent:*`) |
| — | caveman | **not filed — dropped per this spike** |

## Method note

Findings come from three background research workflows using compound-engineering
research agents (`ce-repo-research-analyst`, `ce-web-researcher`,
`ce-best-practices-researcher`), each ending in an adversarial verify pass that
independently tried to refute the highest-stakes claims against primary sources. Source
URLs for every claim are in the raw workflow transcripts.

---

## Part 2 — additional new options

_Pending: a running research pass (`token-optimization-new-options`) is hunting for
options beyond the four tools and the angles above — provider pricing tiers (Flex/Batch),
prompt compression of the instruction surface (LLMLingua), response/tool-result caching,
deterministic pre-computation ("code answers, not the model"), cross-agent shared memory,
and rework-cycle economics. This section will be filled in when it lands._

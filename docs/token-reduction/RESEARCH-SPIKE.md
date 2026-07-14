# Token-Usage Reduction — Research Spike

> **Status:** complete. Three adversarially-verified research workflows (37 agents,
> ~1.68M tokens, 0 errors). **Part 1** covers the four-tool program + first-pass angles.
> **Part 2** covers additional new options and a billing-model reframing that
> reprioritizes the whole effort toward cutting wasted turns and whole re-runs.

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

## Part 2 — additional new options (verified)

A third workflow (12 agents) hunted for options **beyond** the four tools and the Part 1
angles, and adversarially verified the top claims. It surfaced a reframing that changes how
to think about the whole program, plus a set of fleet-native levers that fit better than
two of the original tools.

### The reframing: our cost is a weekly quota, not $/token

**[verified]** Our `~/.codex/auth.json` is `auth_mode=chatgpt` with `OPENAI_API_KEY=null` —
the fleet bills through a **ChatGPT-subscription rate-limit quota** (5-hour rolling + weekly
cap), not metered per-token API spend. Consequences, all verified against primary sources:

- **OpenAI Flex / `service_tier` (~50% off) is a NO-OP for us** and is **struck** from the
  program. Flex requires metered API-key billing; the only tier reachable under chatgpt auth
  is "Fast", which *costs 2–2.5× more*. Even under API-key auth, `service_tier=flex` has open
  silent-ignore bugs (#26604). → Add a cost-hygiene guard that no profile sets
  `service_tier="fast"` (the opposite-direction trap on the same config key).
- Since 2026-04-02 the quota accounting **aligns with token usage** — cached input ~10×
  discounted, **output ~6× pricier** than fresh input (Codex rate card; *not* the unrelated
  "Workspace Agents" product a blog conflated it with **[corrected]**). So the cost driver is
  **fresh output/reasoning tokens**, reinforcing Part 1's #1 lever (reasoning-effort).
- **Reducing the NUMBER of runs/turns** is the highest-leverage new target — not because turn
  count is billed directly, but because **every fresh run re-pays the uncached first-turn
  overhead** (system prompt + skills + tool manifests, ~2–5k tokens) that within-session prefix
  caching otherwise amortizes. This *also* rehabilitates Part 1's skill-slimming lever: a
  smaller always-loaded surface is paid uncached on turn 1 of every run **[corrected: input
  compression is complementary, not "worthless"]**.
- Headroom: `model-usage.json` ≈ 8/100 weekly used — efficiency/scale work, not a fire.

### New top picks — cut wasted turns and whole re-runs (the real quota sink)

All verified against our code; all low effort; ordered by leverage.

1. **Rework continuation prompt + distilled hand-off (HIGH / low).** `turn_prompt.ex` today has
   only *cold* and *resume-after-restart* branches — **[verified: no rework branch]** — so a
   rework whose codex thread-resume has degraded gets the *identical cold prompt* and re-runs
   ce-brainstorm + ce-plan off the same complexity label: a full ~12-turn re-run, the single
   biggest quota sink. Add an `issue.state=="rework"` first-turn branch that forbids re-planning,
   points at the existing `## Agent Workpad`, and injects (as a turn-1 **suffix**, after the
   cached prefix) the unresolved review-thread bodies + a ~30-line deterministic workpad
   distillation. Escape hatch: may re-plan if it records why.
2. **Preserve the codex rollout + CoW worktree across the human-review dwell (HIGH / low).**
   Resume needs the thread's on-disk rollout in `~/.codex`; a ticket can sit in human-review for
   hours while 16 agents churn threads. **[verified mixed]** the rollout is retained *indefinitely
   today* (nothing evicts it — no tunable policy exists, feature-request #6015 is open) and
   `thread/resume` is a real app-server method — so don't reap the CoW worktree on
   deactivation-to-review, **pin `$CODEX_HOME` to a persistent path**, and add a retention ceiling
   (`~/.codex` is already 11 GB+). Compounds with #1 (turns cold reworks into cheap resumes).
3. **Deterministic affected-test selection (HIGH / low).** `prompt.md` tells the *agent* to reason
   over the diff each turn to pick affected tests — a deterministic transform run at model price
   that also risks **under-selection → CI-red → whole-ticket rework**. Replace with a
   `scripts/affected-tests` helper: diff → `src/lib/aiur/X.ex → test/aiur/X_test.exs` (near-1:1)
   expanded via `mix xref graph --sink`, complemented by `mix test --stale`. **[verified mixed]**
   `--stale` *does* track runtime module refs (better than feared) but has real blind spots for
   **Gettext `.po` files** (need `@external_resource`) and **`Application.get_env` runtime config**
   — keep the diff→file map primary and validate those two gaps against our suite. `make ci` stays
   the authoritative full gate, bounding under-selection.
4. **Workspace pre-commit hook (MEDIUM / low).** No git hooks exist today **[verified]**. The agent
   manually runs `mix format` and is told to read `.formatter.exs`/Credo config for a
   lint-clean-first-pass — prevention work at model price. Install a `pre-commit` (via the hooks
   `after_create`) running `mix format` (write-then-restage) + `mix compile --warnings-as-errors`
   so every commit is auto-clean; keep Credo CI-only; don't fight the `before_run` exit-65 guard.
5. **Git-progress stall watchdog (MEDIUM / low).** `runtime_watchdog.ex` caps only on wall-clock +
   codex-stream inactivity **[verified]**, so an agent that streams continuously but produces no
   commits burns to `max_turns:12` / 240 min then gets re-dispatched (maybe cold). Sample `git diff
   --shortstat` between turns; if no advance across K turns while codex streams, **pause + flag the
   Executor** (never auto-kill — false-positive on legitimate deep-analysis turns).

### Medium picks (second wave)

- **Batch multi-persona review into one rework trigger** — `comment_wake.ex` flips idle→rework per
  trusted comment with no debounce, so trickled multi-persona feedback re-engages the agent
  repeatedly (each risking a cold re-run). Hold until all persona passes post, flip once.
- **Pre-PR acceptance self-verify gate** — agent checks its diff against the ticket's explicit
  acceptance-criteria bullets (aiur-build produces them) before human-review, raising first-shot
  acceptance. Value tracks upstream planning quality.
- **`docs/solutions` pull-on-demand learnings** — `ce-compound` + `docs/solutions/` are named but
  not operationalized; populate distilled solved-problem docs agents grep only when relevant (zero
  prompt tokens until read; rides the warm base). Gate writes to one writer at merge.
- **Deterministic gotcha-cards** keyed by label/touched-files, injected as a per-ticket suffix
  (never the shared prefix — no cross-agent cache invalidation). The hand-built `MEMORY.md` proves
  the pattern.
- **Complexity-scaled turn/duration caps** (`max_turns_by_complexity`) so a stuck complexity:1
  ticket caps at ~3 turns instead of 12.
- **Dialyzer core/local PLT split** — audit whether prewarm shares only the core PLT while each
  rework rebuilds the local PLT redundantly; split + incrementally cache.
- **Curated architecture/onboarding map** (small, stable) to collapse first-run "where is X" grep
  exploration — a small AGENTS.md append (stays in the prefix cache) or a warm-base file (pull,
  zero tokens until read). Needs refresh discipline.
- **PR-body scaffold** prefilled from labels to satisfy the `pr_body.check` validator (there's a
  latent template-vs-dev-loop conflict that can bounce PRs to rework).

### Evaluated and down-ranked

- **Prompt compression (LLMLingua-2)** of the instruction/skill surface: a *one-time offline* pass
  could shave the always-loaded prefix, but risks corrupting code/paths and the gain is modest
  given within-session prefix caching; per-request runtime compression adds a model call and busts
  the cache. Prefer plain skill-slimming (Part 1 #5).
- **Semantic/exact response caching** (GPTCache/Helicone): near-worthless for a coding agent where
  every context is near-unique. Tool-result memoization (compile/dialyzer) is the only slice with
  value, folded into the dialyzer-PLT pick above.
- **Batch API**: structurally incompatible with the live tool-calling turn loop.

### Updated program (folding in Part 2)

The four-tool program stands (ccusage → context-mode/Serena trials, **caveman dropped**), but the
**highest-leverage work is now the turn/run-reduction picks above** — most of which are small,
verified changes to our own harness (`turn_prompt.ex`, hooks, watchdog, a test-selection script)
rather than third-party installs. Suggested order once the ccusage baseline exists: reasoning-effort
discrepancy fix → rework-continuation prompt (#1) + rollout preservation (#2) → affected-test
selection (#3) + pre-commit hook (#4) → stall watchdog (#5) → second-wave picks. context-mode and
Serena remain gated trials per Part 1.

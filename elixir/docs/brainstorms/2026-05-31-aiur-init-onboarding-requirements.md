# aiur init — Onboarding Command Requirements

Created: 2026-05-31
Status: draft
Origin: task #23 (supersedes issue #23)

## Problem

Getting started with aiur today means hand-authoring a `WORKFLOW.md`: a
markdown file whose YAML front matter must be written from scratch, with the
right tracker section, agent section, and the GitHub labels that the polling
state machine and routing depend on. Nothing tells a new user which keys exist,
which labels must be created, or whether their agent CLI is even logged in. The
first run usually fails on a missing token or a missing label.

`aiur init` is an interactive, in-repo command that produces a working config
and the labels it needs in one guided pass, so a newcomer goes from clone to a
runnable setup without reading the schema source.

## Goal

A guided wizard, run inside a target repo, that:
- writes a `.aiurconfig` file the runtime auto-detects in the run folder,
- prompts for the decisions that actually branch behavior (tracker, agents,
  concurrency) and silently defaults the rest,
- verifies agent/tracker auth as it goes, surfacing only failures,
- for GitHub trackers, creates the labels aiur relies on, explaining each
  family as it does so.

## Decisions (locked in brainstorm)

### D1 — Config file: `.aiurconfig`, pure YAML
The generated file is named `.aiurconfig` and is **pure YAML** — no embedded
prompt-template body. The runtime currently hardcodes `WORKFLOW.md`
(`elixir/lib/aiur/workflow.ex:8`) resolved from `File.cwd!()`; it must learn to
auto-detect `.aiurconfig` in the run folder. The prompt template moves out of
the config into a separate file (or a shared/default prompt). The exact
relocation mechanism is **deferred to planning** (see Open Questions).

### D2 — Full guided wizard
Walk each prompted section in order with the schema default pre-filled as the
accept-on-enter value. Not a minimal/quick path; not a tiered `--advanced`
split.

### D3 — Sections the wizard prompts for
Only these are asked; every other section is written with its schema default
(from `elixir/lib/aiur/config/schema.ex`) and **not** surfaced:
1. **Tracker + repo/keys** — github vs linear vs memory. For github: repo
   (auto-detect from `git remote`, confirm) and `label_prefix`. For linear:
   API key + project slug.
2. **Agent model(s) + auth** — claude and/or codex, the model name(s), each
   with a background auth check.
3. **Concurrency** — `max_concurrent_agents`, `max_vertical_panes`,
   `pre_warmed_sessions`.

Not prompted (defaulted silently): workspace, opencode, server, polling,
events, hooks, observability.

### D4 — Auth checks: warn + inline retry/skip, then write
Auth checks run in the background per chosen agent and tracker and stay silent
on success. On failure, show the specific error and a fix hint (e.g.
`run claude login`, missing `gh`/Linear token), let the user fix-and-retry
inline or skip, then **write `.aiurconfig` regardless**. Auth is allowed to be
a separate chore; init never traps the user.

### D5 — Existing file: error unless `--force`
If `.aiurconfig` (or a legacy `WORKFLOW.md`) already exists, abort with a
message instructing the user to pass `--force` to overwrite. No in-place
merge/edit or auto-migration in v1.

### D6 — Auto-create GitHub labels, explaining each family
When the tracker is github, the wizard **creates the labels aiur depends on**
(idempotently), telling the user concisely what it's about to do and why, and
defining each family in one line as it goes. There is **no "have you used aiur
before?" question** — the explanation serves every user. Three families:

| Family | Form | Source of truth | What it does |
|--------|------|-----------------|--------------|
| State | `<prefix>:<state>` | active_states + terminal_states; prefix from D3 (`agent` in this repo; code default `aiur`) | Drives the polling state machine (`agent:todo` → `agent:in-progress` → … → `agent:done`). See `elixir/lib/aiur/test_reset.ex:758` for the full set. |
| Model | `model:<backend>[-<variant>]` | `Aiur.CodingAgent.override_labels/0` | Pins which agent/model picks up an issue (`model:claude-opus-4-8`). |
| Complexity | `complexity:1`–`complexity:5` | fixed 1–5 | Routes an issue to a backend via the `agent.routing` table (`elixir/lib/aiur/coding_agent.ex:147`). |

### D7 — Teach complexity→model routing only (truthfully)
The closing guidance tells the user that a `complexity:<n>` label changes
**which model/agent** handles an issue, and `aiur init` writes a starter
`agent.routing` table (e.g. `1–2 → claude, 3–5 → codex`) so the labels do
something out of the box. Complexity does **not** select skills or prompts in
aiur today (one global prompt template, no skill-routing config), so the
tutorial must not claim it does. Per-complexity skills/prompts are explicitly
out of scope for this ticket.

## Scope boundaries

**In scope**
- `aiur init` command + `--force` flag.
- `.aiurconfig` generation (pure YAML) and runtime auto-detection of it.
- Auth checks for chosen agents/tracker.
- GitHub label auto-creation across the three families, with concise
  inline explanations.
- A starter `agent.routing` table.

**Out of scope / deferred**
- Per-complexity skill or prompt selection (would be new routing config +
  `coding_agent.ex` work — its own ticket).
- In-place config merge/migration of an existing file (v1 is error-unless-force).
- Interactive "tag an issue and watch an agent pick it up" walkthrough.
- A Linear equivalent of label auto-creation (Linear's tag model differs —
  see Open Questions).

## Open questions (resolve in planning)

- **Prompt-template relocation (from D1):** separate per-repo file vs. a shared
  built-in default vs. a `prompt_template_path` key. Affects `Aiur.Config` /
  `Aiur.Workflow` and the `@default_prompt_template` in
  `elixir/lib/aiur/config.ex`.
- **`.aiurconfig` detection + back-compat:** does the runtime still fall back to
  `WORKFLOW.md`, and is there a deprecation path? Touches
  `elixir/lib/aiur/workflow.ex` and `workflow_store.ex`.
- **Label-prefix default:** code default is `aiur`; this repo uses `agent`.
  What does the wizard offer as the default prefix?
- **Label creation client + permissions:** which `gh`/REST path, behavior when
  labels already exist (idempotent upsert), and what to do when the token lacks
  write scope.
- **Linear tracker:** does init create anything for Linear, or just configure
  it and skip the GitHub-specific label step?

## Verified grounding (do not relearn)

- Config today: `WORKFLOW.md`, YAML front matter + prompt body, resolved from
  the run folder (`elixir/lib/aiur/workflow.ex:8-14`); override via
  `Application.get_env(:aiur, :workflow_file_path)` or a CLI path arg
  (`elixir/lib/aiur/cli.ex:90-99`). No `init` subcommand exists.
- Schema defaults live in `elixir/lib/aiur/config/schema.ex` (poll 30s,
  max_concurrent_agents 10, max_vertical_panes 3, pre_warmed_sessions 3, server
  127.0.0.1, workspace tmp/aiur_workspaces, etc.).
- Tracker/agent kind are inferred from which section is present
  (`elixir/lib/aiur/config.ex:346-361`); tracker must be one of
  linear|github|memory and agent kind one of `known_backends/0`.
- Backends + seed model variants: `Aiur.CodingAgent.backends/0`
  (claude: opus, sonnet, opus-4-8, sonnet-4-6, haiku-4-5; codex: gpt-5.5).
  `override_labels/0` enumerates the `model:*` labels worth creating.
- Routing precedence: `model:<backend>` override → `complexity:` via
  `agent.routing` → global `agent.kind` (`elixir/lib/aiur/coding_agent.ex:95`).
- State labels are `<label_prefix>:<state>`; this repo's prefix is `agent`
  (`test_reset.ex` hardcodes `agent:todo`…`agent:done`), code default is `aiur`
  (`elixir/lib/aiur/github/config.ex:8`).

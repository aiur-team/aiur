# T-058: Docs: skills page (driver vs workspace-agent)

**Phase:** 5
**Depends-on:** T-055
**Labels:** `agent:todo` `refactor` `phase:5` `complexity:1`

## Problem / context

The VitePress docs package landed by T-055 (built into `website/dist/docs`,
served at `/docs/`, per `docs/refactor/target-architecture.md:114-122`) needs
a page cataloguing Aiur's skill system. Aiur ships two distinct skill
families that today are only documented inside the skill files themselves and
in the feature inventory (`docs/refactor/feature-inventory/skl.md`): the
**driver skills** under `.claude/skills/` that operators and ticket-working
agents load to drive an Aiur run, and the **skills present in agent
workspaces** — the Codex-native git-workflow skills under `.codex/skills/`
plus the compound-engineering (CE) skills the complexity router invokes. A
newcomer reading `/docs/` has no single page that says what each skill is for
or when it fires.

This ticket writes exactly one docs page enumerating both families, one
paragraph per skill, each linking to the skill's `SKILL.md` on disk. It is
pure documentation authoring: no Elixir, no website marketing bundle, no skill
files change. The two families and their members are fixed by the feature
inventory (see Inventory-IDs); the executor makes no decision about which
skills exist or how they are grouped.

## Scope (exact)

The T-055 docs package root is `website/docs-app/` (its VitePress `srcDir`,
containing `.vitepress/config.mts`). All paths below are relative to the repo
root.

1. **Create `website/docs-app/skills.md`.** Front-matter `title: Skills`.
   Open with a 2-3 sentence intro stating that Aiur has two skill families:
   (a) driver skills under `.claude/skills/` and (b) skills present in agent
   workspaces (Codex-native git-workflow skills under `.codex/skills/` plus
   the compound-engineering skills the complexity router invokes). Then two
   H2 sections, in this order and with these members. Write exactly ONE
   paragraph per skill (2-4 sentences): what it is for, and its trigger (the
   phrase or event that fires it). Every skill paragraph MUST link to the
   named `SKILL.md` file using a repo-relative Markdown link exactly as
   spelled below.

2. **Section `## Driver skills`** — six skills, in this order. Each links to
   its `SKILL.md`:
   - **using-aiur** → `../../.claude/skills/using-aiur/SKILL.md`. The
     per-ticket operating manual an agent loads at the start of every ticket
     turn (agent:* label lifecycle, brainstorm→plan→work→review flow, Agent
     Workpad, dev loop). Trigger: loaded every ticket turn via the shared
     per-turn prompt pointer.
   - **aiur-agent** → `../../.claude/skills/aiur-agent/SKILL.md`. The
     cross-ticket event system router (emit_event, aiur_subscribe,
     aiur_declare_blocker, attention open/close). Trigger: agent loads it
     before emitting or subscribing to events.
   - **aiur-run** → `../../.claude/skills/aiur-run/SKILL.md`. The operator
     playbook to launch and babysit a detached `--bg` dogfood run. Trigger:
     "run aiur" / "run IAR" / "iarc run".
   - **aiur-monitor** → `../../.claude/skills/aiur-monitor/SKILL.md`. The
     operator skill that compiles a one-glance status board from `aiurdev
     watch`. Trigger: "aiur status" / "iarc status".
   - **aiur-loop** → `../../.claude/skills/aiur-loop/SKILL.md`. The operator
     skill that runs a sustained improve-this-repo loop (launch + monitor +
     curate + review + merge). Trigger: "run the aiur loop" / "improve this
     repo with aiur".
   - **release** → `../../.claude/skills/release/SKILL.md`. The operator skill
     that cuts a new npm release (bump `src/mix.exs`, tag, GitHub release).
     Trigger: "/release" / "release a new version".

3. **Section `## Skills in agent workspaces`** — begin with one paragraph
   stating that after a workspace is populated, `Aiur.AgentSkills.install/1`
   (`../../src/lib/aiur/agent_skills.ex`) writes the **using-aiur** and
   **aiur-agent** driver skills into `<workspace>/.claude/skills/` and mirrors
   them into `<workspace>/.codex/skills/` via relative symlinks, so agents on
   any repo can load them (link back to the Driver-skills section for those
   two). Then two H3 subsections:

   - **`### Codex-native git-workflow skills`** — six skills committed under
     `.codex/skills/`, in this order, one paragraph each, each linking to its
     `SKILL.md`:
     - **commit** → `../../.codex/skills/commit/SKILL.md`. Codex-native
       conventional-commit flow (read session intent, stage after confirming
       scope, `type(scope)` subject, Codex co-author trailer).
     - **push** → `../../.codex/skills/push/SKILL.md`. Safe push plus PR
       create/update against the PR template; distinguishes sync failures
       (delegate to pull) from auth failures.
     - **pull** → `../../.codex/skills/pull/SKILL.md`. Merge-not-rebase branch
       update with rerere and a conflict-resolution doctrine.
     - **land** → `../../.codex/skills/land/SKILL.md`. End-to-end PR landing:
       stay conflict-free, keep CI green, answer review personas, squash-merge.
     - **debug** → `../../.codex/skills/debug/SKILL.md`. Log-tracing runbook
       for stuck/failing runs via issue/session correlation keys.
     - **linear** → `../../.codex/skills/linear/SKILL.md`. Usage guide for the
       `linear_graphql` app-server tool.

   - **`### Compound-engineering skills`** — one paragraph stating these are
     operator-provided CE skills the complexity router invokes (they are not
     bundled into workspaces by Aiur). Link to
     `../../.claude/skills/using-aiur/complexity-routing.md` as the source of
     the routing rules, and name the set it references: **ce-work**,
     **ce-code-review**, **ce-plan**, **ce-brainstorm**, **ce-doc-review**.
     State plainly that these skills ship with the operator's environment, so
     this page does not link to per-skill files in this repo.

4. **Register the page in the sidebar.** Edit
   `website/docs-app/.vitepress/config.mts` and add a single sidebar entry
   with text `Skills` and link `/skills` in the existing sidebar array. Add
   only that one entry; do not reorder or restyle existing entries. (If
   T-055's config uses a different but equivalent registration shape, add the
   `Skills`→`/skills` entry in that same shape and nothing else.)

5. Keep `website/docs-app/skills.md` under 200 lines. Do not add images,
   custom components, or client JS.

## Files
- Create: `website/docs-app/skills.md`
- Modify: `website/docs-app/.vitepress/config.mts`
- Test: None (docs-only; verified by the docs build + the At-merge checks below)

## Out of scope
- Do NOT edit any skill file under `.claude/skills/` or `.codex/skills/` (this
  page only links to them).
- Do NOT touch `src/lib/aiur/agent_skills.ex` or any Elixir source.
- Do NOT touch the marketing bundle: `website/src/**`, `website/styles.css`,
  `website/netlify.toml`, or the golden snapshot / `scripts/gen-golden.ts`.
- Do NOT create the quick-start, configuration, or concept pages (T-056,
  T-057) or edit their files.
- Do NOT change the VitePress package scaffolding, theme, `package.json`,
  lockfile, or build output config established by T-055.

## Inventory-IDs
Driver skills: FI-SKL-001 (using-aiur), FI-SKL-002 (aiur-agent), FI-SKL-005
(trigger-phrase discovery contract), FI-SKL-033 / FI-SKL-036 (aiur-run),
FI-SKL-038 (aiur-monitor), FI-SKL-045 / FI-SKL-046 (aiur-loop), FI-SKL-048
(release), FI-SKL-037 (iarc alias).
Workspace install mechanism: FI-SKL-050, FI-SKL-052, FI-SKL-054 (bundled
using-aiur + aiur-agent, Codex mirror, operator-vs-worker taxonomy).
Codex-native git-workflow skills: FI-SKL-056 (commit), FI-SKL-057 (debug),
FI-SKL-058 (land), FI-SKL-059 (linear), FI-SKL-060 (pull), FI-SKL-061 (push).
Complexity-routing / CE set: FI-SKL-011.

## Characterization-tests
None. The regression suite under `src/test/aiur/regression/` protects runtime
behavior (panes, warmth, dispatch), not docs pages, and this ticket adds no
Elixir. The skill *files* this page links to are protected by
`src/test/aiur/aiur_agent_skill_test.exs` and
`src/test/aiur/agent_skills_test.exs`, but those are out of scope here because
no skill file is modified.

## Acceptance criteria
- `test -f website/docs-app/skills.md` succeeds and the file is <= 200 lines
  (`wc -l website/docs-app/skills.md`).
- The page has exactly the two H2 sections:
  `grep -c '^## Driver skills$' website/docs-app/skills.md` == 1 and
  `grep -c '^## Skills in agent workspaces$' website/docs-app/skills.md` == 1.
- The two H3 subsections exist:
  `grep -c '^### Codex-native git-workflow skills$'` == 1 and
  `grep -c '^### Compound-engineering skills$'` == 1.
- All six driver-skill links resolve on disk:
  `grep -oE '\.\./\.\./\.claude/skills/[a-z-]+/(SKILL|complexity-routing)\.md' website/docs-app/skills.md`
  lists paths for using-aiur, aiur-agent, aiur-run, aiur-monitor, aiur-loop,
  release, and complexity-routing.md — and each linked file exists (dereference
  each relative to `website/docs-app/`).
- All six Codex git-workflow links resolve on disk:
  `grep -oE '\.\./\.\./\.codex/skills/[a-z-]+/SKILL\.md' website/docs-app/skills.md`
  lists commit, push, pull, land, debug, linear — and each linked file exists.
- The page links the install module once:
  `grep -c '\.\./\.\./src/lib/aiur/agent_skills\.ex' website/docs-app/skills.md`
  >= 1.
- `website/docs-app/.vitepress/config.mts` gained exactly one sidebar entry
  linking `/skills` (`grep -c "'/skills'" website/docs-app/.vitepress/config.mts`
  or the double-quoted equivalent == 1).
- The docs package builds and every internal link resolves (VitePress dead-link
  check passes — see Verification).

## Verification
### Agent gate (run all, from src/)
```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```
Docs package build (from `website/docs-app/`, the T-055 package):
```
bun install
bun run docs:build
```
The VitePress build fails on dead internal links, so a clean
`bun run docs:build` proves every `SKILL.md` / module link on the page
resolves. Marketing-bundle guards remain green and untouched (from
`website/`):
```
npm run typecheck && npm run build && npm run assert
```
### At-merge (reviewer)
- Serve the built docs and open `/docs/skills`: confirm the two skill families
  render, each of the twelve skill paragraphs is a single paragraph with a
  working link, and the CE subsection names ce-work / ce-code-review / ce-plan
  / ce-brainstorm / ce-doc-review without dangling repo links.
- Click every skill link from the rendered page and confirm each lands on the
  correct `SKILL.md` (or `complexity-routing.md` / `agent_skills.ex`).
- Check: the sidebar shows the new `Skills` entry alongside the T-055/T-056/
  T-057 pages with no reordering of existing entries.
- Check: `git diff --stat` touches only `website/docs-app/skills.md` and
  `website/docs-app/.vitepress/config.mts`.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.

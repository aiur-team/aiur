---
ticket_id: MP-E7-C6-T03
feature_id: MP-E7
chunk_id: MP-E7-C6
bucket: 2-platform
title: "Install and uninstall the deliver hook for Claude and Codex Executors without clobbering user hooks"
status: blocked
blocked_by: [DESIGN-E7, DESIGN-E3, MP-E3-C1-T04, MP-E7-C6-T02]
repo: aiur-team/aiur
wave: 4
prior_units: [U4]
prior_boundaries: [EXE, CLD (22), CDX (21)]
prior_features: [MP-E3]
prior_findings: [MP-E7 RQ-E7-6]
size_owner: EXE (executor attach CLI, MP-E3 owner)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C6-T03 — Hook installer for the Executor deliver command

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 2 · MP-E7 · C6.
- **User value:** attaching an Executor (MP-E3) also wires message delivery,
  and detaching removes exactly what aiur added; the operator's own hooks
  (and Khala's) keep working.
- **Deliverable:** the deliver-hook entries (`PostToolUse`,
  `UserPromptSubmit`, `Stop`) added to the hook config that **MP-E3-C1-T04's
  generator** produces, plus an install/uninstall merge for Codex
  `hooks.json` and the Claude settings target E3 chose. One installer, owned
  by E3's generator; this ticket extends it rather than creating a second one.
- **Non-goals:** the CLI command names (`aiur executor-attach
  [--print-config]`, `executor-detach`, MP-E3-C1-T03); trust prompts.

## Dependencies and blockers

- **DESIGN-E7**, **DESIGN-E3** (attach UX);
  **MP-E3-C1-T04** (generator, chooses Claude plugin vs user settings
  snippet — open research in MP-E3 C1); **MP-E7-C6-T02** (command string).
- **May run concurrently with** C6-T04.

## Verified starting point

- aiur at `45a290e3`: `HookSettings` writes a per-session `--settings` file
  for `claude-repl` workers; `claude --settings` **adds** a settings source
  and composes with the user's hooks (`claude/hook_settings.ex:1-9`). That
  path is for sessions aiur launches; an Executor session is launched by the
  operator, so E3 installs into user/project config instead.
- **RQ-E7-6 — resolved for Codex by precedent:** Khala `origin/main`
  `99e72a43` `packages/agent/codex/hooks-config.mjs` `mergeCodexHooks(config,
  action, fragment)` (`:19-59`): rejects a malformed config with
  `invalid_hooks_config` (`:20-27`); on install appends a group per event only
  if no existing hook has the same `command` (`:30-36`); on uninstall removes
  only hooks whose `command` is in the fragment, drops empty groups/events,
  leaves every other handler untouched (`:46-57`). Khala's fragment wires
  `PostToolUse`, `UserPromptSubmit`, `Stop` with `"timeout": 10`
  (`packages/agent/hooks/hooks.codex.json`). aiur ports these rules to
  Elixir (Jason) — same algorithm, no shared code.
- Claude: same rules applied to the `hooks` object of the settings JSON E3
  targets (structure `{"hooks": {Event: [{"hooks": [{"type": "command",
  "command": …}]}]}}`, as aiur already emits at `hook_settings.ex:22-23`).

## Chosen design

- `Aiur.Executor.HookConfig.merge(config_map, :install | :uninstall,
  fragment)` (PROPOSED, pure) implementing the Khala rules, identity by exact
  `command` string. Because the command embeds the base URL and token path,
  uninstall also removes any hook whose command matches the deliver-command
  **prefix** `curl -sS -f -m 3` + `/api/v1/executor/hook/deliver` (handles a
  changed port).
- Fragment: three events, each `{"type": "command", "command": <C6-T02>,
  "timeout": 10}`.
- Writes are atomic (temp file + rename) and keep a `.aiur-backup` of the
  prior file once per install.
- `--print-config` (E3) prints the fragment instead of writing.

## Implementation steps

1. `HookConfig.merge/3` + tests.
2. Extend E3's generator to include the deliver fragment and call
   `merge/3` for install/uninstall.
3. `executor-attach --check` (MP-E3-C7-T01) reports "deliver hook installed:
   yes/no, URL current: yes/no".

## Non-happy paths

- **Malformed user config:** refuse with the file path and
  `invalid_hooks_config`; write nothing.
- **Khala hooks also installed:** both run on the same events. Each prints
  its own envelope. **Open (RQ-E7-C6-2):** how Claude Code and Codex combine
  two `Stop` hooks that both return `decision: "block"` — must be observed in
  the manual test; if one result wins, document that running Khala and aiur
  deliver hooks in one session is unsupported until resolved.
- **Read-only config dir:** error with path; attach still succeeds for
  ingest (E3) and reports delivery as not installed.

## Compatibility and rollout

Changes files in the operator's home/project only on explicit attach. Uninstall
restores the exact non-aiur content. Rollback: `executor-detach`.

## Verification

- `hook_config_test.exs` (new): `"install adds three events once"`;
  `"install twice is idempotent"`; `"uninstall removes only aiur deliver
  hooks and keeps a user Stop hook"` — **mutation:** remove by event instead
  of by command → the user hook disappears → fails;
  `"uninstall removes a deliver hook with an old port"`;
  `"malformed hooks value raises invalid_hooks_config and writes nothing"`.
  Fixtures mirror Khala's merge cases (cited above) plus aiur's prefix case.
- Command: `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec --
  mix test test/aiur/executor`.
- Manual end-to-end (Executor side, not the TUI recipe): with `aiurdev`
  running, `aiur executor-attach --harness claude` in a scratch project with
  an existing user `Stop` hook; start Claude Code there; send a `sync` message
  to the Executor from the dashboard (MP-E3-C5); expect it to appear as a
  continuation after the current turn's `Stop`, the user's own hook still to
  run, and `aiur executor-detach` to leave the user hook intact. Repeat with
  Codex (`hooks.json`).

## Completion and handoff

- [ ] Tests, mutation check, manual capture (both harnesses) in PR.
- [ ] RQ-E7-C6-2 answer recorded in contract §8.
- Docs: `reference/cli.md` rows for attach/detach are MP-E3's; this ticket
  adds one sentence there about delivery hooks (AGENTS.md docs rule).

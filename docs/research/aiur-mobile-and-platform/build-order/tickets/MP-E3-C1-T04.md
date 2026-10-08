---
ticket_id: MP-E3-C1-T04
feature_id: MP-E3
chunk_id: MP-E3-C1
bucket: 2-platform
title: "Hook config generator and installer (Claude project-local settings; Codex printed config)"
status: blocked
blocked_by: [DESIGN-E3, MP-E3-C1-T02]
prior_units: [U4]
prior_boundaries: [EXE, CLD, CDX]
prior_features: [MP-E7-C6-T03 (adds deliver hooks through this generator, CR-E7-3)]
prior_findings: [MP-E3 plan §7 (opt-in = installing hooks); claude/hook_settings.ex invariants]
size_owner: n/a (new module)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C1-T04 — Executor hook config generator and installer

## Identity and outcome

- Bucket 2 · MP-E3 · C1 · T04.
- **User value:** attaching is one command; detaching removes exactly what aiur
  added and nothing the operator wrote.
- **Deliverable:** `Aiur.Executor.HookConfig` with `entries/2`, `render/2`,
  `install/2`, `uninstall/1`, and the daemon-written URL file the hook command
  reads, so hooks keep working when the dashboard port changes across restarts.
- **Non-goals:** the deliver hook command (MP-E7-C6-T02); Codex auto-install.

## Dependencies and blockers

- DESIGN-E3 (OQ-E3-1 harness order; whether installing is automatic or
  print-only for Claude).
- MP-E3-C1-T02 (token and header files, endpoint path).
- CR-E7-3: `entries/2` must accept extra entries so MP-E7-C6-T03 adds its
  deliver hooks through this module, not a second generator.

## Verified starting point

- Worker hook settings today: `Aiur.Claude.HookSettings` builds a `--settings`
  JSON with `UserPromptSubmit`, `PostToolUse`, `Stop`, `StopFailure` and a
  command that is stdout-silent, `curl -m 2`, always `exit 0`
  (`src/lib/aiur/claude/hook_settings.ex:13-45`). It bakes the dashboard URL in
  per session (`:40-44`, `dashboard_url/0` at `:63-70`) — fine for a worker that
  lives one daemon run, wrong for an Executor that outlives restarts.
- Claude hooks can be configured in user, project, local-project settings or a
  plugin (https://code.claude.com/docs/en/hooks, read 2026-10-06, Claude Code
  2.1.291 local). Codex hooks run only after the user trusts them in the TUI
  review dialog, trust stored by hash (MP-E3 plan §2.3; Khala
  `docs/product/internal-mode/interactive-codex.md` at `origin/main 99e72a43`).

## Chosen design

**URL file.** On every HTTP bind the daemon writes
`StatePaths.dir()/<repo>.<instance_key>.executor.hook-url` (0600) with
`http://127.0.0.1:<bound port>` (from `Aiur.HttpServer.bound_port/1`). The hook
command reads it at run time.

**Command** (one string, POSIX sh; stdout-silent; ≤ 2 s; always exit 0):

```sh
AIUR_EXECUTOR_HOOK=1 sh -c 'u=$(cat "<url-file>" 2>/dev/null) || exit 0; curl -sS -m 2 -o /dev/null -H @"<headers-file>" -H "Content-Type: application/json" --data-binary @- "$u/api/v1/executor/hook?harness=<h>" >/dev/null 2>&1; exit 0'
```

- `AIUR_EXECUTOR_HOOK=1` is the ownership marker `uninstall/1` matches on.
- Paths are single-quoted with the same escaping as `HookSettings.single_quote/1`.
- No token in the string (`-H @headers-file`).

**Entries.** `entries(harness, extra \\ [])` → map of event → hook list. Claude
events: `SessionStart`, `UserPromptSubmit`, `PostToolUse`, `Stop`,
`StopFailure`, `SubagentStart`, `SubagentStop`, `Notification`, `SessionEnd`,
`TaskCreated`, `TaskCompleted`. Codex events: `SessionStart`,
`UserPromptSubmit`, `PostToolUse`, `Stop`, `SubagentStart`, `SubagentStop`,
`SessionEnd`. `extra` entries (`%{event, command, timeout}`) are appended per
event — the MP-E7-C6-T03 hook point.

**Install (Claude).** Target: `<repo root>/.claude/settings.local.json`
(project-local scope, so only sessions started in this repository report to
this instance). Read (absent → `{}`), back up to
`settings.local.json.aiur-bak-<ts>`, merge: for each event append aiur's entry
unless an entry with the marker already exists (idempotent), never modify or
reorder other entries, write atomically. If DESIGN-E3 chooses print-only,
`install/2` is not called and `render/2` output is printed.

**Install (Codex).** Print-only: `render(:codex, …)` prints the hooks block and
the target the operator places it in, then the trust instruction. Rationale:
Codex requires an interactive trust step anyway, and silently editing
`~/.codex` is outside this repository.

**Uninstall.** Remove every entry whose command starts with
`AIUR_EXECUTOR_HOOK=1`, drop events left empty, write atomically; keep the
backup.

## Implementation steps

1. `HookConfig` module; URL file writer hooked into the HTTP server's
   post-bind path (`http_server.ex`, where `bound_port` becomes known).
2. Claude installer/uninstaller with JSON merge; Codex renderer.
3. Step 0 manual check (record in PR): run `claude` 2.1.x in a scratch repo with
   the generated `.claude/settings.local.json`, open `/hooks`, confirm the hooks
   are listed from the local settings source and fire (`executor-session` shows
   a hook age).

## Non-happy paths

- `settings.local.json` invalid JSON → refuse to write, print config instead,
  exit 73 (T03); never overwrite an unparsable user file.
- Repo root not writable → same.
- Port changes after restart → the URL file is rewritten; the hook reads it per
  call.
- Daemon stopped → `cat` fails or curl fails fast; the hook exits 0 and the
  session is unaffected.
- Two instances of the same repo in different checkouts → each checkout has its
  own `.claude/settings.local.json` and URL file (instance key in the name).

## Compatibility and rollout

- Only runs on explicit attach. Uninstall restores the previous content except
  formatting. Rollback: `aiur executor-detach`, or delete marked entries by hand.

## Verification

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/executor/hook_config_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "command is stdout-silent and ends with exit 0" | regex on the string | template |
| "command never contains the token" | token absent; `-H @` present | header-file use |
| "install twice is idempotent" | one aiur entry per event | marker check |
| "install keeps user hooks untouched" (fixture with user entries) | user entries byte-equal | merge |
| "uninstall removes only marked entries" | user entries remain | marker match (mutation: remove all fails) |
| "invalid settings JSON is not overwritten" | `{:error, :unparsable}`; file unchanged | guard |
| "extra entries are appended per event" (E7 hook point) | extra present after aiur's | `extra` param |
| "URL file rewritten on bind" | file content = new port | bind hook |

## Completion and handoff

- [ ] Manual Claude check recorded in the PR.
- Dependents: MP-E3-C1-T03 (calls install/uninstall), MP-E7-C6-T03, MP-E3-C7-T01.
- Docs: MP-E3-C7-T02 (what is written where).

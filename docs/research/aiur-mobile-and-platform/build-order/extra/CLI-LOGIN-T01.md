# CLI-LOGIN-T01 — `aiur login --share-history`: share Claude history across accounts

**Tracker:** draft (no issue yet)
**Complexity:** 2
**Phase hint:** 0 (independent of the program waves)
**Depends on:** none

## Outcome

An operator with several Claude accounts sees one history and one project list
in every account. `aiur login <name> --share-history` links the account
profile's history and project directories to `~/.claude`, the way the
`claude/everdred` profile is linked by hand today.

## Context and evidence

`aiur login` creates `~/.aiur/accounts/claude/<name>/` and links only
`Aiur.Accounts.Shims.Claude.shared_paths/0`:
`settings.json`, `CLAUDE.md`, `plugins`, `skills`, `projects/*/memory`.
`never_shared/0` excludes `.claude.json`, `projects/*`, `sessions/`,
`history.jsonl`, `remote-settings.json`, `policy-limits.json`.

The hand-built `everdred` profile (2026-10-07) links more:

| Path in the profile | Target |
|---|---|
| `projects` | `~/.claude/projects` |
| `history.jsonl` | `~/.claude/history.jsonl` |
| `file-history` | `~/.claude/file-history` |
| `session-env` | `~/.claude/session-env` |
| `shell-snapshots` | `~/.claude/shell-snapshots` |
| `todos` | `~/.claude/todos` |
| `plugins`, `skills`, `settings.json`, `CLAUDE.md` | `~/.claude/...` (default today) |

It keeps these local: `.claude.json`, `.credentials.json`, `sessions/`,
`backups/`, `cache/`, `paste-cache/`.

## Scope

- Add `--share-history` to `aiur login` (launcher `run_account_login` in
  `packaging/npm/aiur-cli/libexec/aiur-engine.sh`, `Aiur.AccountsCLI.login/3`).
- A second path list in the Claude shim (for example `history_paths/0`) with the
  six paths above. Apply it only with the flag. `never_shared` still wins for
  credentials and `.claude.json`.
- Existing real directories in the profile are not replaced. Report them and
  name the merge step (the existing `merge_history` helper covers
  `history.jsonl`).
- Record the choice in the account entry so `aiur accounts` shows it.
- Docs: `cli.md` entry for the flag.

## Non-goals

- Codex profiles.
- Sharing credentials or `.claude.json`.

## Existing owner and reuse target

`Aiur.Accounts` (`link_shared_profile/2`, `link_path/4`, `create_link/2`) and
`Aiur.Accounts.Shims.Claude`.

## Acceptance and verification

- A test with a temp HOME: with the flag, the six links exist and point to the
  source; without it, none do. The test fails with the flag handling reverted.
- A pre-existing real `projects/` directory is left untouched and reported.

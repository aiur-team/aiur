# Agent workspaces

Aiur gives each issue an isolated checkout at `<workspace.root>/<repo>/<issue-id>/`.
The workspace is removed during teardown, so files placed inside it are scoped
to that issue.

Agent processes receive `TMPDIR`, `TMP`, and `TEMP` pointing to
`.aiur-runtime/tmp` inside their workspace. Zsh's `TMPPREFIX` uses the same
directory. This keeps temporary files from colliding through the host's shared
`/tmp`; the private directory is created at launch when needed and disappears
with the workspace.

Codex's standard `workspaceWrite` policy also excludes direct access to
`/tmp`. Tools that honor the temporary-directory environment variables keep
working. A command that hardcodes `/tmp` for writes must use the provided temp
directory or another writable workspace path instead.

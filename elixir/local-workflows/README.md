# Local Workflow Templates

These files preserve machine-local operational workflows that have been useful for this checkout.
They are not portable examples and should not be copied as defaults for a new deployment.

Use the workflows in `../examples/workflows/` when setting up a project from scratch. Copy one of
these local files only when you intentionally want the same repository, account, host, workspace, and
service assumptions.

- `WORKFLOW.actions.local.md`: GitHub Issues plus Codex workflow for the local actions fork setup.
- `WORKFLOW.aiur.local.md`: GitHub Issues plus Codex workflow for this Aiur repository.
- `WORKFLOW.aiur-claude.local.md`: Same as `WORKFLOW.aiur.local.md`, but routes agent runs
  through the Claude backend (`agent.kind: claude` → `claude-app-server` / `aiur-claude`).

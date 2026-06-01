# Local Config Templates

These files preserve machine-local operational configs that have been useful for this checkout.
They are not portable examples and should not be copied as defaults for a new deployment.

Use the configs in `../examples/workflows/` when setting up a project from scratch. Copy one of
these local files only when you intentionally want the same repository, account, host, workspace, and
service assumptions. Each `.aiurconfig` references its sibling `.prompt.md` template via `prompt_file:`.

- `actions.local.aiurconfig`: GitHub Issues plus Codex config for the local actions fork setup.
- `aiur.local.aiurconfig`: GitHub Issues plus Codex config for this Aiur repository.

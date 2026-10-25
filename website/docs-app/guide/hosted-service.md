# Hosted service container

Aiur publishes a separate daemon image for single service processes. It runs the daemon in the foreground without tmux, includes `git`, `gh`, Claude Code and Codex, and runs as an unprivileged `aiur` user. The existing `ghcr.io/aiur-team/aiur` image remains the development toolchain image.

`railway.json` builds `packaging/docker/Dockerfile.daemon`, probes `/readyz`, restarts on failure and mounts `/data`. State and Erlang cookie use that volume. Keep `AIUR_STATE_DIR` and `AIUR_BG_STATE_DIR` under `/data`. Supply config with `AIUR_CONFIG_FILE` (default `/data/config`) and set `workspace.root: /data/workspaces` for persistent workspaces.

Set a valid `AIUR_ERLANG_COOKIE` secret, or provide it at `AIUR_COOKIE_FILE` on the mounted volume. The daemon never reads a release-bundled cookie. Set dashboard Basic Auth credentials and tracker/provider credentials through the platform's secret store. Configure the tracker repository and hosted-safe workspace hooks before enabling dispatch.

`GET /healthz` is a public process liveness probe. `GET /readyz` is public and returns `200` only after the orchestrator starts and tracker preflight succeeds; otherwise it returns `503`. Both return fixed text without ticket, budget or credential details. All other dashboard routes keep their configured authentication.

Railway volumes attach to one service and prevent replicas. To run more instances, create more services with separate volumes and distinct instance identities; do not scale one volume-backed service to replicas.

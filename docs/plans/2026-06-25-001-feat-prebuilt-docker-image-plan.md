---
status: completed
issue: 42
created: 2026-06-25
---

# Publish Prebuilt Docker Image Plan

## Problem Frame

Fresh Aiur workspaces should not repeatedly rebuild the same Erlang, Elixir, Hex dependencies, and Mix artifacts before an agent can work. The fresh PR needs to recreate the closed PR #56 design on the current `src/` layout and compose with the newer repo prewarm base.

## Scope

- Publish a cache-friendly GHCR image for this repository on pushes to `main` and published releases.
- Preinstall the pinned mise Erlang/Elixir toolchain and compile `src` dependencies in the image.
- Add optional workspace config that seeds missing warm build directories from the image after the normal checkout refresh path.
- Document the config so operators can opt in without editing hook shell.

Out of scope:

- Running Codex, Claude, or opencode inside the image.
- Multi-arch publishing beyond linux/amd64.
- Replacing the existing `.aiur/prewarm` copy-on-write base.

## Key Decisions

- Use GHCR because GitHub Actions can push `ghcr.io/${{ github.repository }}` with the workflow `GITHUB_TOKEN`.
- Build linux/amd64 first to control CI cost and match the original issue’s “cheap first” path.
- Seed caches by running a short Docker container with the workspace mounted at `/workspace`, copying only missing cache directories from `/opt/aiur`.
- Preserve existing cache directories so resumed workspaces and prewarm-materialized workspaces are not overwritten.

## Implementation Units

### U1. Image Build

**Files:** `Dockerfile`, `.dockerignore`

**Goal:** Build an image containing the repo source at `/opt/aiur`, the pinned mise toolchain, and compiled `src/deps` plus `src/_build`.

**Test scenarios:** Docker build should succeed where a Docker daemon is available; the image should contain `/opt/aiur/src/deps` and `/opt/aiur/src/_build`.

### U2. GHCR Publishing

**Files:** `.github/workflows/publish-image.yml`

**Goal:** Publish `ghcr.io/its-everdred/aiur:latest`, the full commit SHA tag, and release tag refs.

**Test scenarios:** Workflow syntax follows existing pinned-action conventions and uses `packages: write`.

### U3. Workspace Bootstrap Image

**Files:** `src/lib/aiur/config.ex`, `src/lib/aiur/config/schema.ex`, `src/lib/aiur/workspace.ex`, `src/test/aiur/workspace_and_config_test.exs`, `src/test/support/test_support.exs`

**Goal:** Add `workspace.bootstrap_image` and `workspace.bootstrap_image_pull`, then seed missing warm cache directories after `before_run`.

**Test scenarios:** Config defaults are off; empty image values are rejected; fake-Docker tests seed missing `src/deps` and `src/_build`; existing directories are preserved.

### U4. Docs and Examples

**Files:** `src/README.md`, `.aiur/examples/config.example`

**Goal:** Explain the optional bootstrap image settings alongside the existing warm-base prewarm path.

**Test scenarios:** Documentation should make clear the image seeds caches and does not run agents.

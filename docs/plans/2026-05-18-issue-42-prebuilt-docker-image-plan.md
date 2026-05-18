---
status: completed
issue: 42
created: 2026-05-18
---

# Prebuilt Docker Image Warm Bootstrap Plan

## Problem Frame

Fresh Aiur agent workspaces repeatedly install the pinned Erlang/Elixir toolchain and rebuild the same Mix dependencies. The fix should publish a reusable image and give workspace bootstrap a configured path to seed warm Mix artifacts before an agent starts.

## Scope

- Add a cache-friendly Docker image for the Elixir implementation.
- Publish the image to GHCR on pushes to `main`, tagged with `latest` and the commit SHA.
- Add optional workspace configuration that copies `deps/` and `_build/` from the image into the agent checkout.
- Update local/default workflow documentation so operators can opt in without rewriting hooks.

Out of scope for this ticket:

- Running the Codex or Claude app-server inside the image.
- Multi-arch builds unless a later need justifies the extra CI cost.
- Docker Hub publishing.

## Key Decisions

- Registry: GHCR, because the repository already runs on GitHub and `GITHUB_TOKEN` can push package images with scoped workflow permissions.
- Architecture: linux/amd64 first. Apple Silicon can still pull amd64 images through emulation if needed, and avoiding arm64 keeps CI cost down.
- Consumption model: run a short Docker container with the checkout mounted at `/workspace`, then copy warm `deps/` and `_build/` from `/opt/aiur/elixir`. This gives agents the warm build state without needing the app-server binary inside the image.
- Rebuild cadence: build on every `main` push and rely on BuildKit cache. Dependency layers only invalidate when `elixir/mix.lock`, `elixir/mix.exs`, or `elixir/mise.toml` change.

## Implementation Units

### U1: Image Build

Files:

- `Dockerfile`
- `.dockerignore`

Approach:

- Use `elixir/mise.toml` as the toolchain source of truth.
- Copy `mix.exs`, `mix.lock`, and `mise.toml` before the rest of the source so dependency layers cache across source-only changes.
- Pre-fetch and compile Mix dependencies, then compile the app in dev and test environments.

Verification:

- `docker build -t aiur:test .`
- Confirm `/opt/aiur/elixir/deps` and `/opt/aiur/elixir/_build` exist in the image.

### U2: GHCR Publishing

Files:

- `.github/workflows/publish-image.yml`

Approach:

- Trigger on `push` to `main` and `release: published`.
- Authenticate to `ghcr.io` using `GITHUB_TOKEN`.
- Push `ghcr.io/its-everdred/aiur:latest`, `:<sha>`, and release refs when present.

Verification:

- Workflow syntax is valid by inspection and follows repository action patterns.

### U3: Workspace Warm Bootstrap

Files:

- `elixir/lib/aiur/config/schema.ex`
- `elixir/lib/aiur/config.ex`
- `elixir/lib/aiur/workspace.ex`
- `elixir/test/aiur/workspace_and_config_test.exs`
- `elixir/test/support/test_support.exs`

Approach:

- Add optional `workspace.bootstrap_image` and `workspace.bootstrap_image_pull`.
- After `before_run`, run Docker with the workspace mounted and copy missing warm cache directories from the image.
- Preserve existing local workspace safety checks and support remote workers by executing the same Docker command on the selected worker host.

Verification:

- Test config parsing.
- Test local warm bootstrap with a fake Docker executable so tests do not require Docker.
- Test that existing `deps/` and `_build/` are not overwritten.

### U4: Workflow Docs

Files:

- `elixir/WORKFLOW.md`
- `elixir/local-workflows/WORKFLOW.aiur.local.md`
- `elixir/README.md`

Approach:

- Document the optional image settings and enable them in the local Aiur profile for this repository.
- Note that the image seeds caches and does not run the agent itself.

Verification:

- Manual CLI config load using the updated workflow.

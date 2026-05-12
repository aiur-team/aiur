---
date: 2026-05-11
topic: Cross-platform `agents` wrapper (Linux + macOS)
branch: symphony/cross-platform-agents
status: ready-for-implementation
---

# Cross-platform `agents` wrapper

## Summary

Refactor `scripts/agents` so it autodetects OS — systemd `--user` on Linux, `nohup` + PID file on macOS — and resolves its own paths from the script's location, dropping the hardcoded `/home/applekid/…` defaults. Keep the existing command surface. Document the `agents` reference in `elixir/README.md`. Replace the top-level README's "Running Symphony" section with a single link to `elixir/README.md`, dropping the Option 1 / Option 2 framing and the language-agnostic positioning.

## Problem Frame

`scripts/agents` ships in the repo and is tested (`test/scripts_agents_test.exs`, 14 tests) but is undocumented in either README and Linux-only by default. Its hardcoded defaults — `default_repo_root="/home/applekid/github/its-applekid/symphony"`, `mise_bin="$HOME/.local/bin/mise"`, `systemctl_bin="systemctl"` — bake in one author's deployment and assume systemd. On a fresh macOS clone the tests pass (after `brew install bash` for `declare -A`), but the script's runtime defaults don't resolve and background-mode operations (`--bg`, `stop` of a background service) reference `systemctl` which doesn't exist on macOS. There is also no `agents` symlink or alias by default, so users must already know to invoke `./scripts/agents`.

The script has graduated from "personal tooling that happens to be in-repo" to an end-user-facing capability and should ship that way: OS-portable defaults, no hardcoded user paths, and a documented command surface in the Elixir reference's README.

## Requirements

R1. `scripts/agents` autodetects OS at runtime via `uname -s` (Linux vs macOS) and selects the appropriate background-mode backend.

R2. On Linux, background mode continues to use `systemctl --user start|stop|status <service>` against the existing `symphony.service` user unit — unchanged from today.

R3. On macOS, background mode uses `nohup` to detach the process and writes a PID file. `agents --bg` starts a backgrounded `symphony` and records the PID; `agents stop <profile>` reads the PID file, sends `SIGTERM`, removes the PID file, and tolerates a stale PID (process already dead) without erroring.

R4. The `agents` command surface (`agents`, `agents --bg [profile|all]`, `agents stop [profile|all]`, `agents list`, `agents run [profile]`, `agents profile`, `agents <workflow-path>`) is identical on both OSes. No verb, flag, or profile-file syntax changes.

R5. `scripts/agents` resolves the repo root from its own file location (the directory containing the script's parent), so no `AGENTS_REPO_ROOT` env var is needed for a fresh clone. The existing `AGENTS_REPO_ROOT` env var is retained as an override for advanced cases (multi-checkout, per-deployment workflows).

R6. `scripts/agents` finds `mise` via `command -v mise` with `$AGENTS_MISE_BIN` retained as an override. The hardcoded `~/.local/bin/mise` default is removed.

R7. The hardcoded `default_repo_root="/home/applekid/github/its-applekid/symphony"` is removed entirely; no per-user paths remain in the script body.

R8. The macOS PID file lives at `~/.local/state/symphony/<profile>.pid`. The directory is created on first `--bg` if missing.

R9. `test/scripts_agents_test.exs` is extended to cover both OS backends. OS selection is driven by an env var (e.g., `AGENTS_OS_OVERRIDE=darwin|linux`) so the existing Linux test cases stay green and a parallel macOS-mode set exercises the `nohup` + PID-file branch. `systemctl` and `nohup` are stubbed via PATH-shadowed test fixtures the way the existing tests stub `systemctl`/`pkill`.

R10. `elixir/README.md` gains an "Operating Symphony" section (or equivalent — placement chosen at implementation time) listing the `agents` command reference, the `export PATH="$PWD/scripts:$PATH"` install line, and a brief platform notes block calling out the Linux/macOS background-mode difference.

R11. The top-level `README.md`'s `## Running Symphony` section is replaced with a short paragraph linking to `elixir/README.md` for setup and the `agents` reference. The Option 1 / Option 2 framing is removed. The "Implement in your own language" framing (SPEC.md pointer) is dropped from the top README. Tagline, demo video, warning, `## Additional Capabilities`, and license sections above and below stay as-is.

## Key Decisions

K1. **Process-level parity on macOS, not launchd parity.** macOS gets `nohup` + PID file rather than `launchd` plist generation, `launchctl bootstrap`/`bootout`, or auto-restart-on-login. Rationale: Symphony is positioned as a "low-key engineering preview for testing in trusted environments" — production-grade service-manager integration would add plist generation, label conventions, and bootout-on-stop semantics for a workload that doesn't need them yet. The command surface is the parity that matters; the runtime backend can differ.

K2. **No installer.** Users add `scripts/` to PATH themselves; the script reads its own location. Rationale: avoids a self-install code path in the script, avoids decisions about install destination (`~/.local/bin` vs `/usr/local/bin`), and keeps the repo's first-run flow inspectable.

K3. **Profile file stays at `~/.config/symphony/agents.profiles` on both OSes.** No platform-native split (`~/Library/Application Support` on macOS). Rationale: XDG-everywhere matches conventions of comparable dev tools (`mise`, `gh`, `foundry`) and matches what the script does today, so existing Linux users have nothing to migrate.

K4. **OS detection via `uname -s` with a test-mode override.** A single switch point (`case "$(uname -s)" in Linux*) ...; Darwin*) ...; esac`) keeps the backend selection mechanical, and the test override lets a single CI machine exercise both branches.

K5. **Existing Linux deployment continues to work with no env-var changes.** The author's current `/home/applekid/…` box happens to have the script at the right location for the new autodetection to resolve to the same repo root, and `mise` is at a path `command -v mise` will find. The `$AGENTS_REPO_ROOT` and `$AGENTS_MISE_BIN` overrides remain for anyone whose layout differs.

K6. **Separate PR from `symphony/agent-chat-send`.** Orthogonal scope, different reviewers' attention, doesn't block the chat-send Phase 9 smoke (chat-send Phase 9 will benefit from this work landing first, but doesn't depend on it).

## Scope Boundaries

- `launchd` plist generation, `launchctl bootstrap`/`bootout`, auto-restart-on-login, or auto-restart-on-crash on macOS
- A self-installing symlink at `~/.local/bin/agents` or any one-shot installer script
- Platform-specific profile-file paths (`~/Library/Application Support/symphony/…`)
- Changes to the `agents` command surface (verbs, flag shapes, profile-file syntax, or new commands)
- Touching the `symphony/agent-chat-send` branch or anything in `docs/plans/2026-05-11-feat-agent-chat-send-plan.md`
- Web dashboard auth, port, or `symphony.service` user unit shape (existing Linux unit stays as-is)
- Rewriting the top-level README beyond the `## Running Symphony` section (tagline, demo, warning, Additional Capabilities, license stay)
- Re-positioning the project beyond removing the language-agnostic "Option 1 / Option 2" framing; no new strategic copy added
- Background-mode parity on Linux when systemd is unavailable (e.g., WSL without systemd, minimal containers); systemd is assumed on Linux as today

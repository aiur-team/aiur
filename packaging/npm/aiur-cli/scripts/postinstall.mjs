#!/usr/bin/env node
// Provisions the peer tools every aiur user needs at runtime, so that a single
// global `npm install -g aiur-cli` yields a working install with nothing left
// to install by hand:
//
//   - tmux      the multiplexer the interactive TUI runs inside. aiur refuses
//               to launch without tmux >= MIN_TMUX, so it is a hard runtime
//               requirement (not merely nice-to-have).
//   - opencode  the peer CLI behind the interactive "take the wheel" panes.
//
// A global aiur-cli install does not link a dependency's bin onto PATH, and
// tmux is a system package rather than an npm one, so we provision both here.
// Every step is idempotent (skips when already satisfied) and non-fatal (a
// failure prints a hint but never breaks the aiur install).
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";

// ---------------------------------------------------------------------------
// opencode
// ---------------------------------------------------------------------------

// Pinned opencode version, read from package.json `opencodeVersion` (single
// source of truth — keep in sync with mise.toml). aiur's opencode pane
// integration is validated against this version; 1.17.x broke custom-provider
// model resolution (ProviderModelNotFoundError), blanking the chat panes.
const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
export const OPENCODE_PACKAGE = `opencode-ai@${pkg.opencodeVersion}`;

// True only when the *pinned* opencode version is on PATH. A wrong (e.g.
// newer) version must be reinstalled — leaving 1.17.x in place keeps the
// panes broken — so a mere presence check isn't enough.
export function opencodeMatchesPin() {
  const result = spawnSync("opencode", ["--version"], { encoding: "utf8" });
  return !result.error && result.status === 0 && result.stdout.trim() === pkg.opencodeVersion;
}

// Build the nested-install command. Provisioning fetches opencode from the
// registry, so it must NOT inherit an offline context from the outer
// `npm install` that triggered this postinstall — CI's `npm install -g
// --offline`, a `prefer-offline` config, or an air-gapped box. npm hands those
// to lifecycle scripts as npm_config_* env vars; a naive nested install
// inherits them and dies with ENOTCACHED on a cold cache, silently leaving
// opencode unprovisioned. We force online two ways (CLI flags outrank env, and
// stripping the env vars is belt-and-suspenders) so a plain `npm install -g
// aiur-cli` provisions opencode regardless of how the parent was invoked.
export function opencodeInstallSpec(env = process.env) {
  const childEnv = { ...env };
  delete childEnv.npm_config_offline;
  delete childEnv.npm_config_prefer_offline;
  return {
    command: "npm",
    args: ["install", "-g", OPENCODE_PACKAGE, "--no-offline", "--no-prefer-offline"],
    env: childEnv,
  };
}

export function installOpencode() {
  const spec = opencodeInstallSpec();
  const result = spawnSync(spec.command, spec.args, { stdio: "inherit", env: spec.env });
  return !result.error && result.status === 0;
}

export function provisionOpencode({
  env = process.env,
  isPresent = opencodeMatchesPin,
  install = installOpencode,
  log = (message) => process.stderr.write(message + "\n"),
} = {}) {
  if (env.AIUR_SKIP_OPENCODE_INSTALL === "1") return "skipped:disabled";
  if (isPresent()) return "skipped:present";

  log(`aiur: installing pinned opencode (${OPENCODE_PACKAGE}) for the interactive 'take the wheel' feature…`);

  if (install()) return "installed";

  log(
    "aiur: couldn't install opencode automatically. Install it manually: " +
      "npm install -g opencode-ai (see https://opencode.ai)",
  );
  return "failed";
}

// ---------------------------------------------------------------------------
// tmux
// ---------------------------------------------------------------------------

// Minimum tmux the TUI needs. Keep in sync with the runtime preflight in
// bin/aiur.js — that preflight stays as a safety net, this just front-loads
// the install so the first `aiur` run isn't a dead end.
export const MIN_TMUX = [3, 3];

function tmuxHint(platform = process.platform) {
  return platform === "darwin"
    ? "install it with: brew install tmux"
    : "install it with: apt install tmux (or your distro's package manager)";
}

// True only when a new-enough tmux is on PATH. The TUI won't launch with an
// older tmux, so — as with opencode's pin — presence alone isn't enough.
export function tmuxSatisfiesMin(run = (cmd, argv) => spawnSync(cmd, argv, { encoding: "utf8" })) {
  const result = run("tmux", ["-V"]);
  if (result.error || result.status !== 0) return false;
  const match = /tmux\s+(\d+)\.(\d+)/.exec(result.stdout || "");
  if (!match) return false;
  const major = Number(match[1]);
  const minor = Number(match[2]);
  const [needMajor, needMinor] = MIN_TMUX;
  return major > needMajor || (major === needMajor && minor >= needMinor);
}

// Best-effort system install of tmux. macOS uses Homebrew; Linux uses the
// first package manager that is present. Returns false (so the caller can
// print a manual hint) when no usable installer exists or the install fails —
// including the common non-root case where a Linux package manager can't
// proceed. We never invoke sudo: a hidden password prompt during `npm install`
// would hang the install.
export function installTmux(platform = process.platform) {
  const has = (bin) => !spawnSync(bin, ["--version"], { stdio: "ignore" }).error;

  if (platform === "darwin") {
    if (!has("brew")) return false;
    return spawnSync("brew", ["install", "tmux"], { stdio: "inherit" }).status === 0;
  }

  if (platform === "linux") {
    const managers = [
      ["apt-get", ["install", "-y", "tmux"]],
      ["dnf", ["install", "-y", "tmux"]],
      ["apk", ["add", "tmux"]],
      ["pacman", ["-S", "--noconfirm", "tmux"]],
    ];
    for (const [bin, argv] of managers) {
      if (!has(bin)) continue;
      return spawnSync(bin, argv, { stdio: "inherit" }).status === 0;
    }
  }

  return false;
}

export function provisionTmux({
  env = process.env,
  isPresent = tmuxSatisfiesMin,
  install = installTmux,
  platform = process.platform,
  log = (message) => process.stderr.write(message + "\n"),
} = {}) {
  if (env.AIUR_SKIP_TMUX_INSTALL === "1") return "skipped:disabled";
  if (isPresent()) return "skipped:present";

  log(
    `aiur: tmux (>= ${MIN_TMUX.join(".")}) not found; aiur's interactive TUI runs inside tmux. Installing…`,
  );

  if (install(platform)) return "installed";

  log(`aiur: couldn't install tmux automatically. ${tmuxHint(platform)}`);
  return "failed";
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

// Run only when invoked directly as the postinstall step, not when a test
// imports the helpers above. tmux is provisioned first — it is the hard
// requirement — then opencode for the optional panes.
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  provisionTmux();
  provisionOpencode();
}

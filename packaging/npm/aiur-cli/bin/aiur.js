#!/usr/bin/env node
"use strict";

const { spawnSync, spawn } = require("node:child_process");
const path = require("node:path");
const fs = require("node:fs");
const os = require("node:os");

// Node's spawnSync reports a missing executable via `result.error`; some
// runtimes (e.g. Bun) throw instead. Normalize to the error-return shape so a
// missing tmux/opencode/brew degrades gracefully rather than crashing.
function safeSpawn(command, args, options) {
  try {
    return spawnSync(command, args, options);
  } catch (error) {
    return { error, status: null, stdout: "" };
  }
}

// Map this host to the platform package that carries its OTP release.
const PLATFORMS = {
  "darwin arm64": "darwin-arm64",
  "darwin x64": "darwin-x64",
  "linux arm64": "linux-arm64",
  "linux x64": "linux-x64",
};

const MIN_TMUX = [3, 3];

function fail(message) {
  process.stderr.write(`aiur: ${message}\n`);
  process.exit(1);
}

function resolveReleaseDir() {
  // A pre-set AIUR_RELEASE_DIR (the dev shim, or local `npm pack` install
  // verification) wins over platform-package resolution.
  const preset = process.env.AIUR_RELEASE_DIR;
  if (preset) {
    try {
      if (fs.statSync(preset).isDirectory()) return preset;
    } catch (_) {
      // fall through to the explicit error below
    }
    fail(`AIUR_RELEASE_DIR is set but not a directory: ${preset}`);
  }

  const triple = PLATFORMS[`${process.platform} ${process.arch}`];
  if (!triple) {
    fail(
      `unsupported platform ${process.platform}/${process.arch}. ` +
        "Supported: linux (x64/arm64) and darwin (arm64). " +
        "See https://github.com/aiur-team/aiur",
    );
  }

  const pkg = `aiur-cli-${triple}`;
  let pkgJson;
  try {
    pkgJson = require.resolve(`${pkg}/package.json`);
  } catch (err) {
    if (err && err.code === "MODULE_NOT_FOUND") {
      fail(
        `platform package "${pkg}" is not installed. ` +
          "This usually means optional dependencies were skipped " +
          "(--no-optional, a shared lockfile, or a known npm install bug). " +
          "Reinstall aiur-cli, or see https://github.com/aiur-team/aiur",
      );
    }
    throw err;
  }

  return path.join(path.dirname(pkgJson), "release");
}

// Pinned opencode version — single source of truth is this package's
// package.json `opencodeVersion` (kept in sync with scripts/postinstall.mjs
// and mise.toml).
function opencodeVersion() {
  const pkg = JSON.parse(
    fs.readFileSync(path.join(__dirname, "..", "package.json"), "utf8"),
  );
  return pkg.opencodeVersion;
}

// ---------------------------------------------------------------------------
// Lazy first-run provisioning
//
// The npm postinstall (scripts/postinstall.mjs) provisions tmux + opencode, but
// bun/pnpm/yarn block postinstall scripts by default — a package cannot force a
// consumer to run them. So the launcher guarantees the peer tools here, on the
// first real (TUI) launch, regardless of which package manager installed
// aiur-cli. Both steps are idempotent (skip when already satisfied); tmux is a
// hard requirement, opencode is best-effort. Honors the same AIUR_SKIP_* env
// vars as the postinstall. This logic mirrors postinstall.mjs intentionally —
// the launcher stays dependency-free and cannot import the .mjs counterpart.
// ---------------------------------------------------------------------------

function tmuxVersion() {
  const result = safeSpawn("tmux", ["-V"], { encoding: "utf8" });
  if (result.error || result.status !== 0) return null;
  const match = /tmux\s+(\d+)\.(\d+)/.exec(result.stdout || "");
  if (!match) return null;
  return [Number(match[1]), Number(match[2])];
}

function tmuxSatisfiesMin() {
  const version = tmuxVersion();
  if (!version) return false;
  const [major, minor] = version;
  const [needMajor, needMinor] = MIN_TMUX;
  return major > needMajor || (major === needMajor && minor >= needMinor);
}

function tmuxHint() {
  return process.platform === "darwin"
    ? "install it with: brew install tmux"
    : "install it with: apt install tmux (or your distro's package manager)";
}

// Best-effort system install of tmux. macOS uses Homebrew; Linux uses the first
// package manager present. Never invokes sudo (a hidden password prompt mid-
// launch would hang). Returns false so the caller can fail with a clear hint.
function installTmux(platform) {
  const has = (bin) => !safeSpawn(bin, ["--version"], { stdio: "ignore" }).error;
  if (platform === "darwin") {
    if (!has("brew")) return false;
    return safeSpawn("brew", ["install", "tmux"], { stdio: "inherit" }).status === 0;
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
      return safeSpawn(bin, argv, { stdio: "inherit" }).status === 0;
    }
  }
  return false;
}

// tmux is required — the TUI runs inside it — so this provisions if missing and
// fails hard only when tmux still can't be made available.
function ensureTmux() {
  if (tmuxSatisfiesMin()) return;
  if (process.env.AIUR_SKIP_TMUX_INSTALL !== "1") {
    process.stderr.write(
      `aiur: tmux (>= ${MIN_TMUX.join(".")}) runs the interactive TUI; installing it…\n`,
    );
    installTmux(process.platform);
  }
  if (!tmuxSatisfiesMin()) {
    const v = tmuxVersion();
    fail(
      v
        ? `tmux ${v[0]}.${v[1]} is too old; aiur needs >= ${MIN_TMUX.join(".")}. ${tmuxHint()}`
        : `tmux is required but was not found on PATH. ${tmuxHint()}`,
    );
  }
}

// True only when the pinned opencode is on PATH; a wrong (e.g. newer,
// unverified) version must be replaced with the pin, so presence alone
// isn't enough.
function opencodeMatchesPin() {
  const result = safeSpawn("opencode", ["--version"], { encoding: "utf8" });
  return !result.error && result.status === 0 && (result.stdout || "").trim() === opencodeVersion();
}

// Install the pinned opencode globally. Forces online so it never inherits an
// --offline / prefer-offline context (CI, mirrors, air-gapped) that would fail
// on a cold cache — mirrors scripts/postinstall.mjs:installOpencode.
function installOpencode() {
  const env = { ...process.env };
  delete env.npm_config_offline;
  delete env.npm_config_prefer_offline;
  const result = safeSpawn(
    "npm",
    ["install", "-g", `opencode-ai@${opencodeVersion()}`, "--no-offline", "--no-prefer-offline"],
    { stdio: "inherit", env },
  );
  return !result.error && result.status === 0;
}

// opencode powers the interactive "take the wheel" panes. Non-fatal: everything
// else works without it.
function ensureOpencode() {
  if (opencodeMatchesPin()) return;
  if (process.env.AIUR_SKIP_OPENCODE_INSTALL !== "1") {
    process.stderr.write(
      `aiur: provisioning opencode@${opencodeVersion()} (one-time, for the interactive 'take the wheel' panes)…\n`,
    );
    installOpencode();
    if (opencodeMatchesPin()) return;
  }
  process.stderr.write(
    "aiur: opencode was not found on PATH. The interactive 'take the wheel' " +
      "feature needs it; everything else works without it. " +
      "Install from https://opencode.ai\n",
  );
}

// `init` and `--version` run as foreground one-shots that never start the
// tmux-backed UI, so their tmux/opencode provisioning is irrelevant — and tmux
// may legitimately be absent on a machine that only ever runs `aiur init`.
function isForegroundOneShot(argv) {
  for (const arg of argv) {
    if (arg === "--version") return true;
    if (arg.startsWith("-")) continue;
    return arg === "init";
  }
  return false;
}

function main() {
  const releaseDir = resolveReleaseDir();

  if (!isForegroundOneShot(process.argv.slice(2))) {
    ensureTmux();
    ensureOpencode();
  }

  const pkgRoot = path.resolve(__dirname, "..");
  const launcher = path.join(pkgRoot, "libexec", "aiur-engine.sh");

  const result = spawnSync(launcher, process.argv.slice(2), {
    stdio: "inherit",
    env: {
      ...process.env,
      AIUR_RELEASE_DIR: releaseDir,
      AIUR_TMUX_CONF: path.join(pkgRoot, "share", "aiur.tmux.conf"),
    },
  });

  if (result.error) {
    fail(`failed to launch ${launcher}: ${result.error.message}`);
  }
  if (result.signal) {
    process.kill(process.pid, result.signal);
    return;
  }
  process.exit(result.status === null ? 1 : result.status);
}

main();

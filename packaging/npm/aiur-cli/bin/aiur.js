#!/usr/bin/env node
"use strict";

const { spawnSync } = require("node:child_process");
const path = require("node:path");
const fs = require("node:fs");

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
        "Supported: darwin/linux on arm64/x64. " +
        "See https://github.com/its-everdred/aiur",
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
          "Reinstall aiur-cli, or see https://github.com/its-everdred/aiur",
      );
    }
    throw err;
  }

  return path.join(path.dirname(pkgJson), "release");
}

function tmuxVersion() {
  const result = spawnSync("tmux", ["-V"], { encoding: "utf8" });
  if (result.error || result.status !== 0) return null;
  const match = /tmux\s+(\d+)\.(\d+)/.exec(result.stdout || "");
  if (!match) return null;
  return [Number(match[1]), Number(match[2])];
}

function tmuxHint() {
  return process.platform === "darwin"
    ? "install it with: brew install tmux"
    : "install it with: apt install tmux (or your distro's package manager)";
}

function preflightTmux() {
  const version = tmuxVersion();
  if (!version) {
    fail(`tmux is required but was not found on PATH. ${tmuxHint()}`);
  }
  const [major, minor] = version;
  const [needMajor, needMinor] = MIN_TMUX;
  const tooOld =
    major < needMajor || (major === needMajor && minor < needMinor);
  if (tooOld) {
    fail(
      `tmux ${major}.${minor} is too old; aiur needs ` +
        `>= ${needMajor}.${needMinor}. ${tmuxHint()}`,
    );
  }
}

function preflightOpencode() {
  const result = spawnSync("opencode", ["--version"], { stdio: "ignore" });
  if (result.error || result.status !== 0) {
    process.stderr.write(
      "aiur: opencode was not found on PATH. The interactive 'take the wheel' " +
        "feature needs it; everything else works without it. " +
        "Install from https://opencode.ai\n",
    );
  }
}

// `init` and `--version` run as foreground one-shots that never start the
// tmux-backed UI, so their tmux/opencode preflight is irrelevant — and tmux may
// legitimately be absent on a machine that only ever runs `aiur init`.
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
    preflightTmux();
    preflightOpencode();
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

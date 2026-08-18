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

// ---------------------------------------------------------------------------
// Update notifier
//
// When a newer aiur-cli is published, surface a one-line "update available"
// notice — npm-update-notifier style: every run reads a small cache file and
// prints from it; the registry is only hit in a detached background worker,
// at most once per interval, so the check never blocks or errors the command.
// The notice always goes to stderr so piped stdout stays clean.
//
// This file is its own background worker: main() re-spawns it with
// AIUR_UPDATE_NOTIFIER_WORKER=1 set, which short-circuits to runUpdateWorker().
// Keeps the launcher dependency-free (a tiny semver compare + https.get).
// ---------------------------------------------------------------------------

const UPDATE_CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000; // 24h
const REGISTRY_LATEST_URL = "https://registry.npmjs.org/aiur-cli/latest";
// Unpublished/source builds carry this sentinel; never nag on a dev checkout.
const DEV_VERSION = "0.0.0";

function currentVersion() {
  try {
    const pkg = JSON.parse(
      fs.readFileSync(path.join(__dirname, "..", "package.json"), "utf8"),
    );
    return typeof pkg.version === "string" ? pkg.version : null;
  } catch (_) {
    return null;
  }
}

// Minimal semver: parse major.minor.patch with an optional prerelease tag.
// Enough for the launcher's own clean release versions — not a full spec impl.
// The regex is fully anchored (and tolerates a +build suffix) so a registry- or
// cache-supplied string with trailing junk — e.g. control/ANSI bytes meant to
// hijack the terminal when the notice is printed — fails to parse and is treated
// as not-newer rather than reaching printUpdateNotice verbatim.
function parseSemver(value) {
  const match = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(
    String(value).trim(),
  );
  if (!match) return null;
  return { major: +match[1], minor: +match[2], patch: +match[3], pre: match[4] || "" };
}

// True when `a` is strictly newer than `b`. A release outranks a prerelease at
// the same core version (1.0.0 > 1.0.0-rc.1); unparseable input is never newer.
function semverGt(a, b) {
  const pa = parseSemver(a);
  const pb = parseSemver(b);
  if (!pa || !pb) return false;
  if (pa.major !== pb.major) return pa.major > pb.major;
  if (pa.minor !== pb.minor) return pa.minor > pb.minor;
  if (pa.patch !== pb.patch) return pa.patch > pb.patch;
  if (pa.pre === pb.pre) return false;
  if (!pa.pre) return true; // a is a release, b is a prerelease
  if (!pb.pre) return false; // a is a prerelease, b is a release
  return pa.pre > pb.pre; // both prereleases: lexical tiebreak
}

function cacheFile() {
  const base = process.env.XDG_CACHE_HOME
    ? path.join(process.env.XDG_CACHE_HOME, "aiur")
    : path.join(os.homedir(), ".aiur");
  return path.join(base, "update-check.json");
}

function readCache() {
  try {
    return JSON.parse(fs.readFileSync(cacheFile(), "utf8"));
  } catch (_) {
    return null;
  }
}

function writeCache(data) {
  try {
    const file = cacheFile();
    fs.mkdirSync(path.dirname(file), { recursive: true });
    // Write-then-rename so a reader never sees a half-written file: if the
    // detached worker is killed mid-write, or two workers race, the rename is
    // atomic on POSIX and a torn cache can't trigger a respawn-every-run loop.
    const tmp = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(data));
    fs.renameSync(tmp, file);
  } catch (_) {
    // A missing-cache write must never break the run; silently skip.
  }
}

// Treat any non-falsy CI value except an explicit "false"/"0" as a CI run.
function isCI() {
  const value = process.env.CI;
  return !!value && value !== "false" && value !== "0";
}

function notifierDisabled(current) {
  return (
    process.env.AIUR_NO_UPDATE_NOTIFIER === "1" ||
    isCI() ||
    !current ||
    current === DEV_VERSION
  );
}

function printUpdateNotice(current, latest) {
  process.stderr.write(
    `aiur: a new version is available — ${current} → ${latest}\n` +
      "      update: npm install -g aiur-cli@latest\n",
  );
}

// Synchronous, fast, never-throwing: print from cache when a newer version is
// known, then kick off a detached refresh if the cache is stale. The notice is
// TTY-gated so non-interactive/piped invocations stay quiet.
function maybeNotifyUpdate() {
  try {
    const current = currentVersion();
    if (notifierDisabled(current)) return;

    const cache = readCache();
    if (
      cache &&
      cache.latest &&
      process.stderr.isTTY &&
      semverGt(cache.latest, current)
    ) {
      printUpdateNotice(current, cache.latest);
    }

    const stale =
      !cache ||
      typeof cache.lastCheck !== "number" ||
      Date.now() - cache.lastCheck > UPDATE_CHECK_INTERVAL_MS;
    if (stale) spawnUpdateWorker();
  } catch (_) {
    // The version check is best-effort; never let it affect the command.
  }
}

function spawnUpdateWorker() {
  try {
    const child = spawn(process.execPath, [__filename], {
      detached: true,
      stdio: "ignore",
      env: { ...process.env, AIUR_UPDATE_NOTIFIER_WORKER: "1" },
    });
    child.unref();
  } catch (_) {
    // If we can't detach a worker, just skip — the next run retries.
  }
}

// Fetch the `latest` dist-tag's version. Bounded by a timeout and a response
// cap; any error resolves to null so the worker stays silent when offline.
function fetchLatestVersion(url, done) {
  let settled = false;
  const finish = (value) => {
    if (settled) return;
    settled = true;
    done(value);
  };
  try {
    const transport = url.startsWith("http://") ? require("node:http") : require("node:https");
    const req = transport.get(
      url,
      { headers: { Accept: "application/json" }, timeout: 5000 },
      (res) => {
        if (res.statusCode !== 200) {
          res.resume();
          return finish(null);
        }
        let body = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => {
          body += chunk;
          // Abort an oversized body. req.destroy() emits only "close" (no "end"
          // or "error"), so resolve here explicitly — otherwise the worker would
          // hang forever and never stamp the cache, respawning on every run.
          if (body.length > 1_000_000) {
            req.destroy();
            finish(null);
          }
        });
        res.on("end", () => {
          try {
            const version = JSON.parse(body).version;
            finish(typeof version === "string" ? version : null);
          } catch (_) {
            finish(null);
          }
        });
      },
    );
    // A timeout's req.destroy() likewise emits only "close", so resolve here too
    // rather than waiting on an event that never comes. "error" covers the
    // connection-failure case (offline, refused).
    req.on("timeout", () => {
      req.destroy();
      finish(null);
    });
    req.on("error", () => finish(null));
  } catch (_) {
    finish(null);
  }
}

// Detached worker entrypoint: refresh the cache, then exit. Always stamps
// lastCheck (even on failure) so an offline machine doesn't respawn every run.
function runUpdateWorker() {
  const previous = readCache();
  const url = process.env.AIUR_REGISTRY_URL || REGISTRY_LATEST_URL;
  fetchLatestVersion(url, (latest) => {
    writeCache({
      lastCheck: Date.now(),
      // Keep the last known `latest` when the fetch fails so a transient outage
      // doesn't drop a pending notice.
      latest: latest || (previous && previous.latest) || null,
    });
    process.exit(0);
  });
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
  // Detached refresh worker: do only the registry check, never the real launch.
  if (process.env.AIUR_UPDATE_NOTIFIER_WORKER === "1") {
    runUpdateWorker();
    return;
  }

  maybeNotifyUpdate();

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

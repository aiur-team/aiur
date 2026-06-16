#!/usr/bin/env node
// Provisions opencode on install. opencode is a peer CLI every aiur user
// needs for the interactive "take the wheel" panes. A global aiur-cli
// install does not link a dependency's bin onto PATH, so we install
// opencode globally here instead. Idempotent (skips when already present)
// and non-fatal (a failure prints a hint but never breaks the aiur install).
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";

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

export function installOpencode() {
  const result = spawnSync("npm", ["install", "-g", OPENCODE_PACKAGE], { stdio: "inherit" });
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

// Run only when invoked directly as the postinstall step, not when a test
// imports the helpers above.
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  provisionOpencode();
}

#!/usr/bin/env node
// Provisions opencode on install. opencode is a peer CLI every aiur user
// needs for the interactive "take the wheel" panes. A global aiur-cli
// install does not link a dependency's bin onto PATH, so we install
// opencode globally here instead. Idempotent (skips when already present)
// and non-fatal (a failure prints a hint but never breaks the aiur install).
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

export function opencodeOnPath() {
  const result = spawnSync("opencode", ["--version"], { stdio: "ignore" });
  return !result.error && result.status === 0;
}

export function installOpencode() {
  const result = spawnSync("npm", ["install", "-g", "opencode-ai"], { stdio: "inherit" });
  return !result.error && result.status === 0;
}

export function provisionOpencode({
  env = process.env,
  isPresent = opencodeOnPath,
  install = installOpencode,
  log = (message) => process.stderr.write(message + "\n"),
} = {}) {
  if (env.AIUR_SKIP_OPENCODE_INSTALL === "1") return "skipped:disabled";
  if (isPresent()) return "skipped:present";

  log("aiur: installing opencode (opencode-ai) for the interactive 'take the wheel' feature…");

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

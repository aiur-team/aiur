#!/usr/bin/env node
// Stamp every aiur npm package to a single version and pin the launcher's
// optionalDependencies to that exact version. Run in the publish job so all
// five packages (launcher + four platform packages) move in lockstep.
//
// Usage: stamp-versions.mjs <version>

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const TARGETS = ["linux-x64", "linux-arm64", "darwin-x64", "darwin-arm64"];
const VERSION_RE = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/;

function die(message) {
  process.stderr.write(`stamp-versions: ${message}\n`);
  process.exit(1);
}

const version = process.argv[2];
if (!version || !VERSION_RE.test(version)) {
  die(`invalid version "${version ?? ""}". Expected a semver string like 1.2.3.`);
}

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const launcherPkgPath = path.join(repoRoot, "packaging", "npm", "aiur-cli", "package.json");
const platformDir = path.join(repoRoot, "packaging", "npm", "platform");

// Validate everything before mutating anything.
if (!existsSync(launcherPkgPath)) die(`launcher package.json missing at ${launcherPkgPath}`);

const launcher = JSON.parse(readFileSync(launcherPkgPath, "utf8"));
launcher.version = version;
launcher.optionalDependencies = Object.fromEntries(
  TARGETS.map((t) => [`aiur-cli-${t}`, version]),
);
writeFileSync(launcherPkgPath, JSON.stringify(launcher, null, 2) + "\n");
process.stdout.write(`aiur-cli -> ${version}\n`);

for (const target of TARGETS) {
  const pkgPath = path.join(platformDir, `aiur-cli-${target}`, "package.json");
  if (!existsSync(pkgPath)) continue; // generated separately in CI; skip if not assembled here
  const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
  pkg.version = version;
  writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + "\n");
  process.stdout.write(`aiur-cli-${target} -> ${version}\n`);
}

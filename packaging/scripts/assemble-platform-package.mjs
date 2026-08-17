#!/usr/bin/env node
// Turn a built OTP release tree into a publishable per-platform npm package.
//
// Output: packaging/npm/platform/aiur-cli-<target>/ containing the release
// tree, a generated package.json with os/cpu guards, and the license files.
// Nothing runs at install time (no bin, no postinstall) — the main aiur-cli
// package resolves this one and execs its bundled launcher.
//
// Usage:
//   assemble-platform-package.mjs --release <dir> --target <triple> --version <vsn>
//   (target is one of linux-x64, linux-arm64, darwin-x64, darwin-arm64)

import { cpSync, mkdirSync, rmSync, writeFileSync, existsSync, copyFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const TARGETS = {
  "linux-x64": { os: "linux", cpu: "x64" },
  "linux-arm64": { os: "linux", cpu: "arm64" },
  "darwin-x64": { os: "darwin", cpu: "x64" },
  "darwin-arm64": { os: "darwin", cpu: "arm64" },
};

function die(message) {
  process.stderr.write(`assemble-platform-package: ${message}\n`);
  process.exit(1);
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key.startsWith("--") || value === undefined) {
      die(`malformed argument near "${key}"`);
    }
    out[key.slice(2)] = value;
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
const { release, target, version } = args;

if (!release || !target || !version) {
  die("required: --release <dir> --target <triple> --version <vsn>");
}

const platform = TARGETS[target];
if (!platform) {
  die(`unknown target "${target}". Valid targets: ${Object.keys(TARGETS).join(", ")}`);
}

const releaseDir = path.resolve(release);
if (!existsSync(releaseDir)) {
  die(`release tree not found at ${releaseDir}`);
}

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const license = path.join(repoRoot, "LICENSE");
const notice = path.join(repoRoot, "NOTICE");
for (const f of [license, notice]) {
  if (!existsSync(f)) die(`expected license file missing: ${f}`);
}

const pkgName = `aiur-cli-${target}`;
const outDir = path.join(repoRoot, "packaging", "npm", "platform", pkgName);

rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });

cpSync(releaseDir, path.join(outDir, "release"), { recursive: true });
copyFileSync(license, path.join(outDir, "LICENSE"));
copyFileSync(notice, path.join(outDir, "NOTICE"));

const pkgJson = {
  name: pkgName,
  version,
  description: `aiur OTP release for ${platform.os}/${platform.cpu}`,
  license: "Apache-2.0",
  homepage: "https://github.com/aiur-team/aiur",
  // Required, not cosmetic. Publishing under OIDC trusted publishing attaches a
  // sigstore provenance attestation naming the source repo, and npm rejects the
  // upload with 422 unless repository.url agrees with it. Omitting this field
  // reads as "" and fails every platform package:
  //   Failed to validate repository information: package.json: "repository.url"
  //   is "", expected to match "https://github.com/aiur-team/aiur" from provenance
  // Keep in sync with packaging/npm/aiur-cli/package.json.
  repository: {
    type: "git",
    url: "git+https://github.com/aiur-team/aiur.git",
  },
  os: [platform.os],
  cpu: [platform.cpu],
  files: ["release", "LICENSE", "NOTICE"],
};
writeFileSync(path.join(outDir, "package.json"), JSON.stringify(pkgJson, null, 2) + "\n");

process.stdout.write(`${outDir}\n`);

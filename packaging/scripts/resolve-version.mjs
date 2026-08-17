#!/usr/bin/env node
// Resolve the npm version and dist-tag for a release channel.
//
// `src/mix.exs` is the single source of truth for the Aiur version. Every npm
// package version is derived from it, so the repo — not the registry and not a
// hand-edited package.json — decides what gets published.
//
//   stable   -> <mix>                       dist-tag: latest
//   nightly  -> <mix>-nightly.<short-sha>   dist-tag: nightly
//   dev      -> <mix>-dev.<run>             dist-tag: none (never published)
//
// A stable cut driven by a `v*` tag must agree with mix.exs; a mismatch is a
// hard error rather than a silently mis-versioned publish.
//
// Usage:
//   resolve-version.mjs --channel <stable|nightly|dev> [--tag <ref>]
//                       [--sha <sha>] [--run <n>] [--format <shell|plain>]

import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const CHANNELS = new Set(["stable", "nightly", "dev"]);
const BASE_RE = /^\d+\.\d+\.\d+$/;

function die(message) {
  process.stderr.write(`resolve-version: ${message}\n`);
  process.exit(1);
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key.startsWith("--") || value === undefined) die(`malformed argument near "${key}"`);
    out[key.slice(2)] = value;
  }
  return out;
}

export function readMixVersion(repoRoot) {
  const mixPath = path.join(repoRoot, "src", "mix.exs");
  const source = readFileSync(mixPath, "utf8");
  const match = source.match(/^\s*version:\s*"([^"]+)"/m);
  if (!match) die(`no version: "x.y.z" found in ${mixPath}`);
  if (!BASE_RE.test(match[1])) die(`mix.exs version "${match[1]}" is not a bare x.y.z version`);
  return match[1];
}

export function resolve({ channel, base, tag, sha, run }) {
  if (!CHANNELS.has(channel)) {
    die(`unknown channel "${channel}". Valid: ${[...CHANNELS].join(", ")}`);
  }

  if (channel === "stable") {
    // A dispatched stable cut has no tag; GITHUB_REF is then a branch ref and
    // is ignored rather than treated as a version.
    if (tag && tag.startsWith("refs/tags/")) {
      const tagged = tag.slice("refs/tags/".length).replace(/^v/, "");
      if (tagged !== base) {
        die(
          `tag v${tagged} does not match src/mix.exs version ${base}. ` +
            `Bump mix.exs and retag, or tag v${base}.`,
        );
      }
    }
    return { version: base, distTag: "latest", publish: true };
  }

  if (channel === "nightly") {
    if (!sha) die("--sha is required for the nightly channel");
    const short = sha.slice(0, 7);
    if (!/^[0-9a-f]{7}$/.test(short)) die(`--sha "${sha}" is not a git object id`);
    // SemVer sorts prereleases below the release, so <base>-nightly.<sha> can
    // never be picked up by a caret range on <base> or by `latest`.
    return { version: `${base}-nightly.${short}`, distTag: "nightly", publish: true };
  }

  if (!run) die("--run is required for the dev channel");
  return { version: `${base}-dev.${run}`, distTag: "", publish: false };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = parseArgs(process.argv.slice(2));
  const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
  const base = readMixVersion(repoRoot);
  const r = resolve({
    channel: args.channel ?? "dev",
    base,
    tag: args.tag,
    sha: args.sha,
    run: args.run,
  });

  if (args.format === "plain") {
    process.stdout.write(`${r.version}\n`);
  } else {
    process.stdout.write(
      [
        `base=${base}`,
        `version=${r.version}`,
        `dist_tag=${r.distTag}`,
        `publish=${r.publish}`,
      ].join("\n") + "\n",
    );
  }
}

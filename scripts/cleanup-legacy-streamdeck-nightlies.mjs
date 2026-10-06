#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const LEGACY_TAG = /^streamdeck-[0-9a-f]{40}$/;

function gh(args) {
  return execFileSync("gh", args, { encoding: "utf8" });
}

function readReleases(repo) {
  const rows = gh([
    "api",
    "--paginate",
    `repos/${repo}/releases`,
    "--jq",
    ".[] | [.tag_name, .prerelease] | @json",
  ]);

  return rows
    .split(/\r?\n/)
    .filter(Boolean)
    .map((row) => {
      const [tag_name, prerelease] = JSON.parse(row);
      return { tag_name, prerelease };
    });
}

export function selectLegacyNightlies(releases) {
  const matches = releases.filter(
    (release) => typeof release.tag_name === "string" && LEGACY_TAG.test(release.tag_name),
  );
  const stable = matches.filter((release) => release.prerelease !== true);

  if (stable.length > 0) {
    throw new Error(
      `refusing to delete non-prerelease Stream Deck releases: ${stable.map((r) => r.tag_name).join(", ")}`,
    );
  }

  return matches;
}

export function removeLegacyNightlies(repo) {
  const releases = selectLegacyNightlies(readReleases(repo));
  console.log(`Removing ${releases.length} legacy per-commit Stream Deck prereleases:`);

  for (const { tag_name } of releases) {
    console.log(tag_name);
    gh(["release", "delete", tag_name, "--yes", "--cleanup-tag"]);
  }

  const remainingReleases = selectLegacyNightlies(readReleases(repo));
  const remainingTags = gh([
    "api",
    "--paginate",
    `repos/${repo}/tags`,
    "--jq",
    ".[] | .name",
  ])
    .split(/\r?\n/)
    .filter((tag) => LEGACY_TAG.test(tag));

  if (remainingReleases.length > 0 || remainingTags.length > 0) {
    throw new Error(
      `legacy Stream Deck refs remain after cleanup: releases=${remainingReleases.length}, tags=${remainingTags.length}`,
    );
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const repo = process.env.GH_REPO;
  if (!repo || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) {
    throw new Error("GH_REPO must be an owner/repo pair");
  }

  removeLegacyNightlies(repo);
}

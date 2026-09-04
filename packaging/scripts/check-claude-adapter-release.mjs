#!/usr/bin/env node
// Verify the exact aiur-claude version required by Aiur is obtainable from
// the public npm registry. A missing release is version drift; registry
// outages and malformed responses are reported separately so infrastructure
// uncertainty is never mislabeled as non-publication.
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PACKAGE = "aiur-claude";
const PUBLIC_REGISTRY = "https://registry.npmjs.org";
const UPSTREAM_MAIN_PACKAGE =
  "https://raw.githubusercontent.com/aiur-team/aiur-claude/main/package.json";
const REQUEST_TIMEOUT_MS = 10_000;
const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const defaultSourcePath = path.join(repoRoot, "src", "lib", "aiur", "claude", "adapter_health.ex");

export function extractMinimumVersion(source) {
  const matches = [...source.matchAll(/^\s*@min_version\s+"([^"]+)"\s*$/gm)];

  if (matches.length === 0) throw new Error("missing @min_version declaration");
  if (matches.length > 1) throw new Error(`expected one @min_version declaration, found ${matches.length}`);

  const version = matches[0][1];
  if (!validSemanticVersion(version)) {
    throw new Error(`@min_version must be a valid semantic version, got ${JSON.stringify(version)}`);
  }

  return version;
}

function validSemanticVersion(version) {
  return /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(version);
}

function infrastructureUncertainty(reason) {
  return { status: "infrastructure_uncertainty", reason };
}

function upstreamUncertainty(reason) {
  return { ...infrastructureUncertainty(reason), source: "upstream_main" };
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

async function fetchJson(url, options) {
  const fetchFn = options.fetchFn ?? globalThis.fetch;
  const timeoutMs = options.timeoutMs ?? REQUEST_TIMEOUT_MS;

  let response;
  try {
    response = await fetchFn(url, {
      cache: "no-store",
      headers: { accept: "application/json" },
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (error) {
    return { ok: false, kind: "request", reason: errorMessage(error) };
  }

  if (!response.ok) return { ok: false, kind: "http", status: response.status };

  try {
    return { ok: true, metadata: await response.json() };
  } catch (error) {
    return { ok: false, kind: "metadata", reason: errorMessage(error) };
  }
}

export async function checkPublishedRelease(packageName, version, options = {}) {
  const registryUrl = options.registryUrl ?? PUBLIC_REGISTRY;
  const url = `${registryUrl.replace(/\/$/, "")}/${encodeURIComponent(packageName)}/${encodeURIComponent(version)}`;
  const fetched = await fetchJson(url, options);

  if (!fetched.ok && fetched.kind === "http" && fetched.status === 404) {
    return { status: "unpublished", httpStatus: 404 };
  }
  if (!fetched.ok && fetched.kind === "http") {
    return infrastructureUncertainty(`registry returned HTTP ${fetched.status}`);
  }
  if (!fetched.ok && fetched.kind === "request") {
    return infrastructureUncertainty(`registry request failed: ${fetched.reason}`);
  }
  if (!fetched.ok) {
    return infrastructureUncertainty(`registry returned malformed metadata: ${fetched.reason}`);
  }

  const metadata = fetched.metadata;
  if (!metadata || typeof metadata !== "object" || metadata.version !== version) {
    const reported = metadata && typeof metadata === "object" ? metadata.version : undefined;
    return infrastructureUncertainty(
      `registry metadata reported version ${reported === undefined ? "(missing)" : reported}, expected ${version}`,
    );
  }

  return { status: "available", version };
}

export async function checkUpstreamMainRelease(options = {}) {
  const fetched = await fetchJson(UPSTREAM_MAIN_PACKAGE, options);

  if (!fetched.ok && fetched.kind === "http") {
    return upstreamUncertainty(`upstream main returned HTTP ${fetched.status}`);
  }
  if (!fetched.ok && fetched.kind === "request") {
    return upstreamUncertainty(`upstream main request failed: ${fetched.reason}`);
  }
  if (!fetched.ok) {
    return upstreamUncertainty(`upstream main returned malformed metadata: ${fetched.reason}`);
  }

  const metadata = fetched.metadata;
  if (!metadata || typeof metadata !== "object" || metadata.name !== PACKAGE) {
    const reported = metadata && typeof metadata === "object" ? metadata.name : undefined;
    return upstreamUncertainty(
      `upstream main reported package name ${reported === undefined ? "(missing)" : reported}, expected ${PACKAGE}`,
    );
  }

  if (!validSemanticVersion(metadata.version)) {
    return upstreamUncertainty(`upstream main reported invalid version ${JSON.stringify(metadata.version)}`);
  }

  const result = await checkPublishedRelease(PACKAGE, metadata.version, options);
  return { ...result, version: metadata.version, source: "upstream_main" };
}

export function formatResult(packageName, version, result) {
  return `check-claude-adapter-release: ${formatStatus(packageName, version, result)}`;
}

function formatStatus(packageName, version, result) {
  const packageRef = `${packageName}@${version}`;

  switch (result.status) {
    case "available":
      return `OK — ${packageRef} is published on the public npm registry`;
    case "unpublished":
      return `unpublished — ${packageRef} is absent from the public npm registry (HTTP ${result.httpStatus})`;
    case "infrastructure_uncertainty":
      return `infrastructure uncertainty — could not verify ${packageRef}: ${result.reason}`;
    default:
      return `infrastructure uncertainty — unknown result while verifying ${packageRef}`;
  }
}

function formatUpstreamResult(result) {
  if (result.status === "infrastructure_uncertainty" && !result.version) {
    return `check-claude-adapter-release: infrastructure uncertainty — could not resolve upstream main: ${result.reason}`;
  }

  return `check-claude-adapter-release: upstream main — ${formatStatus(PACKAGE, result.version, result)}`;
}

function writeResult(result, output, stdout, stderr) {
  const stream = result.status === "available" ? stdout : stderr;
  stream.write(`${output}\n`);
  return result.status === "available" ? 0 : 1;
}

export async function run(options = {}) {
  const stdout = options.stdout ?? process.stdout;
  const stderr = options.stderr ?? process.stderr;

  if (options.mode === "upstream_main") {
    const result = await checkUpstreamMainRelease(options);
    return writeResult(result, formatUpstreamResult(result), stdout, stderr);
  }

  const sourcePath = options.sourcePath ?? defaultSourcePath;

  let version;
  try {
    version = extractMinimumVersion(readFileSync(sourcePath, "utf8"));
  } catch (error) {
    stderr.write(
      `check-claude-adapter-release: declaration error — ${errorMessage(error)}\n`,
    );
    return 1;
  }

  const result = await checkPublishedRelease(PACKAGE, version, options);
  return writeResult(result, formatResult(PACKAGE, version, result), stdout, stderr);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  if (args.length === 0) {
    process.exitCode = await run();
  } else if (args.length === 1 && args[0] === "--upstream-main") {
    process.exitCode = await run({ mode: "upstream_main" });
  } else {
    process.stderr.write("usage: check-claude-adapter-release.mjs [--upstream-main]\n");
    process.exitCode = 1;
  }
}

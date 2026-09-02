import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import {
  checkPublishedRelease,
  checkUpstreamMainRelease,
  extractMinimumVersion,
  formatResult,
  run,
} from "../check-claude-adapter-release.mjs";

const PACKAGE = "aiur-claude";
const VERSION = "1.1.0";

function outputSink() {
  let output = "";
  return {
    stream: { write: (chunk) => (output += chunk) },
    read: () => output,
  };
}

test("extracts the declared minimum version from the shared Elixir module", () => {
  const source = `defmodule Aiur.Claude.AdapterHealth do\n  @min_version "1.1.0"\nend\n`;

  assert.equal(extractMinimumVersion(source), VERSION);
});

test("rejects missing and malformed minimum-version declarations", () => {
  assert.throws(() => extractMinimumVersion("defmodule Empty do\nend\n"), /missing @min_version/);
  assert.throws(() => extractMinimumVersion('  @min_version "next"\n'), /valid semantic version/);
});

test("an exact matching registry response is available", async () => {
  let requestedUrl;
  const fetchFn = async (url) => {
    requestedUrl = url;
    return new Response(JSON.stringify({ name: PACKAGE, version: VERSION }), { status: 200 });
  };

  const result = await checkPublishedRelease(PACKAGE, VERSION, { fetchFn });

  assert.deepEqual(result, { status: "available", version: VERSION });
  assert.equal(requestedUrl, `https://registry.npmjs.org/${PACKAGE}/${VERSION}`);
});

test("a registry 404 is classified as unpublished", async () => {
  const fetchFn = async () => new Response("not found", { status: 404 });

  assert.deepEqual(await checkPublishedRelease(PACKAGE, VERSION, { fetchFn }), {
    status: "unpublished",
    httpStatus: 404,
  });
  assert.match(formatResult(PACKAGE, VERSION, { status: "unpublished", httpStatus: 404 }), /unpublished/);
});

test("a registry 5xx is infrastructure uncertainty", async () => {
  const fetchFn = async () => new Response("unavailable", { status: 503 });
  const result = await checkPublishedRelease(PACKAGE, VERSION, { fetchFn });

  assert.equal(result.status, "infrastructure_uncertainty");
  assert.match(result.reason, /HTTP 503/);
  assert.match(formatResult(PACKAGE, VERSION, result), /infrastructure uncertainty/);
});

test("a network failure is infrastructure uncertainty", async () => {
  const fetchFn = async () => {
    throw new TypeError("fetch failed");
  };
  const result = await checkPublishedRelease(PACKAGE, VERSION, { fetchFn });

  assert.equal(result.status, "infrastructure_uncertainty");
  assert.match(result.reason, /fetch failed/);
});

test("malformed registry metadata is infrastructure uncertainty", async () => {
  const fetchFn = async () => new Response("not-json", { status: 200 });
  const result = await checkPublishedRelease(PACKAGE, VERSION, { fetchFn });

  assert.equal(result.status, "infrastructure_uncertainty");
  assert.match(result.reason, /malformed metadata/);
});

test("mismatched registry metadata is infrastructure uncertainty", async () => {
  const fetchFn = async () =>
    new Response(JSON.stringify({ name: PACKAGE, version: "1.0.0" }), { status: 200 });
  const result = await checkPublishedRelease(PACKAGE, VERSION, { fetchFn });

  assert.equal(result.status, "infrastructure_uncertainty");
  assert.match(result.reason, /reported version 1\.0\.0/);
});

test("the CLI contract exits nonzero and reports a confirmed unpublished release", async (t) => {
  const root = mkdtempSync(path.join(tmpdir(), "aiur-claude-release-check-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const sourcePath = path.join(root, "adapter_health.ex");
  writeFileSync(sourcePath, `defmodule Fixture do\n  @min_version "${VERSION}"\nend\n`);
  const stdout = outputSink();
  const stderr = outputSink();

  const status = await run({
    sourcePath,
    stdout: stdout.stream,
    stderr: stderr.stream,
    fetchFn: async () => new Response("not found", { status: 404 }),
  });

  assert.equal(status, 1);
  assert.equal(stdout.read(), "");
  assert.match(stderr.read(), /unpublished/);
  assert.match(stderr.read(), /aiur-claude@1\.1\.0/);
});

test("upstream main resolves its package version and checks that exact npm release", async () => {
  const requests = [];
  const fetchFn = async (url) => {
    requests.push(url);
    if (url.includes("raw.githubusercontent.com")) {
      return new Response(JSON.stringify({ name: PACKAGE, version: VERSION }), { status: 200 });
    }
    return new Response(JSON.stringify({ name: PACKAGE, version: VERSION }), { status: 200 });
  };

  const result = await checkUpstreamMainRelease({ fetchFn });

  assert.deepEqual(result, { status: "available", version: VERSION, source: "upstream_main" });
  assert.deepEqual(requests, [
    "https://raw.githubusercontent.com/aiur-team/aiur-claude/main/package.json",
    `https://registry.npmjs.org/${PACKAGE}/${VERSION}`,
  ]);
});

test("upstream main ahead of npm is classified as unpublished drift", async () => {
  const fetchFn = async (url) =>
    url.includes("raw.githubusercontent.com")
      ? new Response(JSON.stringify({ name: PACKAGE, version: VERSION }), { status: 200 })
      : new Response("not found", { status: 404 });

  assert.deepEqual(await checkUpstreamMainRelease({ fetchFn }), {
    status: "unpublished",
    httpStatus: 404,
    version: VERSION,
    source: "upstream_main",
  });
});

test("upstream fetch and metadata failures are infrastructure uncertainty", async () => {
  const cases = [
    [async () => new Response("unavailable", { status: 503 }), /HTTP 503/],
    [async () => Promise.reject(new TypeError("upstream network failed")), /network failed/],
    [async () => new Response("not-json", { status: 200 }), /malformed metadata/],
    [
      async () => new Response(JSON.stringify({ name: "wrong-package", version: VERSION }), { status: 200 }),
      /package name wrong-package/,
    ],
    [async () => new Response(JSON.stringify({ name: PACKAGE, version: "next" }), { status: 200 }), /invalid version/],
  ];

  for (const [fetchFn, reason] of cases) {
    const result = await checkUpstreamMainRelease({ fetchFn });
    assert.equal(result.status, "infrastructure_uncertainty");
    assert.equal(result.source, "upstream_main");
    assert.match(result.reason, reason);
  }
});

test("upstream CLI mode reports package-version drift", async (t) => {
  const stdout = outputSink();
  const stderr = outputSink();
  const fetchFn = async (url) =>
    url.includes("raw.githubusercontent.com")
      ? new Response(JSON.stringify({ name: PACKAGE, version: VERSION }), { status: 200 })
      : new Response("not found", { status: 404 });

  const status = await run({ mode: "upstream_main", stdout: stdout.stream, stderr: stderr.stream, fetchFn });

  assert.equal(status, 1);
  assert.equal(stdout.read(), "");
  assert.match(stderr.read(), /upstream main/);
  assert.match(stderr.read(), /unpublished/);
  assert.match(stderr.read(), /aiur-claude@1\.1\.0/);
});

test("scheduled monitoring uses upstream mode while required lint checks the local declaration", () => {
  const monitor = readFileSync(
    new URL("../../../.github/workflows/claude-adapter-release-monitor.yml", import.meta.url),
    "utf8",
  );
  const ci = readFileSync(new URL("../../../.github/workflows/ci.yml", import.meta.url), "utf8");

  assert.match(monitor, /check-claude-adapter-release\.mjs --upstream-main/);
  assert.match(ci, /node packaging\/scripts\/check-claude-adapter-release\.mjs\n/);
  assert.doesNotMatch(ci, /check-claude-adapter-release\.mjs --upstream-main/);
});

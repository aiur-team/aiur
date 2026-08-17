import { test, expect, beforeEach, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const realScript = fileURLToPath(new URL("../resolve-version.mjs", import.meta.url));

let root;
let scriptCopy;

// Mirror the repo layout in a temp tree and run a copy of the script so its
// repoRoot (derived from its own location) points at the fixture, not the repo.
function setup(mixVersion = "1.2.3") {
  root = mkdtempSync(path.join(tmpdir(), "aiur-resolve-"));
  mkdirSync(path.join(root, "packaging", "scripts"), { recursive: true });
  scriptCopy = path.join(root, "packaging", "scripts", "resolve-version.mjs");
  copyFileSync(realScript, scriptCopy);

  mkdirSync(path.join(root, "src"), { recursive: true });
  writeFileSync(
    path.join(root, "src", "mix.exs"),
    ["def project do", "  [", "    app: :aiur,", `    version: "${mixVersion}",`, "  ]", "end", ""].join(
      "\n",
    ),
  );
}

function run(...args) {
  return spawnSync(process.execPath, [scriptCopy, ...args], { encoding: "utf8" });
}

function fields(stdout) {
  return Object.fromEntries(
    stdout
      .trim()
      .split("\n")
      .map((line) => line.split("=")),
  );
}

beforeEach(() => setup());
afterEach(() => rmSync(root, { recursive: true, force: true }));

test("stable takes the version from mix.exs and targets latest", () => {
  const result = run("--channel", "stable", "--tag", "refs/tags/v1.2.3");
  expect(result.status).toBe(0);
  expect(fields(result.stdout)).toMatchObject({
    base: "1.2.3",
    version: "1.2.3",
    dist_tag: "latest",
    publish: "true",
  });
});

test("stable ignores a branch ref so a dispatched cut works without a tag", () => {
  const result = run("--channel", "stable", "--tag", "refs/heads/main");
  expect(result.status).toBe(0);
  expect(fields(result.stdout).version).toBe("1.2.3");
});

test("a tag that disagrees with mix.exs is a hard error", () => {
  const result = run("--channel", "stable", "--tag", "refs/tags/v9.9.9");
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("does not match src/mix.exs version 1.2.3");
});

test("nightly is a prerelease of the next version, tagged nightly", () => {
  const result = run("--channel", "nightly", "--sha", "49210b06f2afdc105d5bb43e44bc2a8a");
  expect(result.status).toBe(0);
  expect(fields(result.stdout)).toMatchObject({
    version: "1.2.3-nightly.49210b0",
    dist_tag: "nightly",
    publish: "true",
  });
});

// SemVer sorts any prerelease below its release, so `<base>-...` can never be
// selected by a range on <base> or reached by `npm install aiur-cli`. That also
// means <base> itself must be an UNRELEASED version: cutting a nightly for a
// version already on the registry would sort below something published.
test("nightly sorts below the release it leads to", () => {
  const { version, base } = fields(run("--channel", "nightly", "--sha", "abcdef1234").stdout);
  expect(version.startsWith(`${base}-`)).toBe(true);
});

test("nightly requires a sha", () => {
  const result = run("--channel", "nightly");
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("--sha is required");
});

test("dev never publishes and carries no dist-tag", () => {
  const result = run("--channel", "dev", "--run", "42");
  expect(result.status).toBe(0);
  expect(fields(result.stdout)).toMatchObject({ version: "1.2.3-dev.42", publish: "false" });
  expect(result.stdout).toContain("dist_tag=\n");
});

test("an unknown channel is rejected", () => {
  const result = run("--channel", "beta");
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("unknown channel");
});

test("a prerelease already in mix.exs is rejected as a base", () => {
  rmSync(root, { recursive: true, force: true });
  setup("1.2.3-rc.1");
  const result = run("--channel", "stable");
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("not a bare x.y.z version");
});

test("--format plain prints only the version", () => {
  const result = run("--channel", "stable", "--format", "plain");
  expect(result.stdout).toBe("1.2.3\n");
});

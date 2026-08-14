#!/usr/bin/env node

import { chmod, cp, mkdir, mkdtemp, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  const key = process.argv[index];
  const value = process.argv[index + 1];
  if (!key?.startsWith("--") || value === undefined) throw new Error(`expected --key value, got ${key ?? "nothing"}`);
  args.set(key.slice(2), value);
}

const required = (name) => {
  const value = args.get(name);
  if (!value) throw new Error(`--${name} is required`);
  return value;
};

const output = resolve(args.get("output") ?? join(packageRoot, "package-dist"));
const commit = required("commit");
const version = required("version");
const sourceDateEpoch = required("source-date-epoch");
const releaseTag = args.get("release-tag") ?? `streamdeck-${commit}`;
if (!/^[0-9a-f]{40}$/i.test(commit)) throw new Error("--commit must be a full Git commit SHA");
if (!/^\d+$/.test(sourceDateEpoch)) throw new Error("--source-date-epoch must be Unix seconds");

const run = (command, commandArgs, options = {}) => {
  const result = spawnSync(command, commandArgs, { encoding: "utf8", ...options });
  if (result.status !== 0) throw new Error(`${command} failed: ${result.stderr || result.stdout}`);
  return result.stdout;
};
const sha256 = async (path) => createHash("sha256").update(await readFile(path)).digest("hex");

await stat(join(packageRoot, "dist", "main.js"));
await stat(join(packageRoot, "node_modules", "usb"));
try {
  await stat(join(packageRoot, "node_modules", "vitest"));
  throw new Error("production dependencies are required; run npm prune --omit=dev before packaging");
} catch (error) {
  if (error?.code !== "ENOENT") throw error;
}
const nodeBinary = process.execPath;
await stat(nodeBinary);

const target = `${process.platform}-${process.arch}`;
if (target !== "linux-x64") throw new Error(`only linux-x64 packages are supported, got ${target}`);
const artifactBase = `aiur-streamdeck-${version}-${target}`;
await mkdir(output, { recursive: true });
const stage = await mkdtemp(join(output, ".stage-"));
const root = join(stage, artifactBase);

try {
  await mkdir(join(root, "bin"), { recursive: true });
  await mkdir(join(root, "runtime"), { recursive: true });
  await mkdir(join(root, "app"), { recursive: true });
  await mkdir(join(root, "share", "udev"), { recursive: true });
  await mkdir(join(root, "share", "systemd"), { recursive: true });
  const bundledNode = join(root, "runtime", "node");
  await writeFile(bundledNode, await readFile(nodeBinary), { mode: 0o755 });
  await chmod(bundledNode, 0o755);
  await cp(join(packageRoot, "dist"), join(root, "app", "dist"), { recursive: true });
  const nodeModulesSource = join(packageRoot, "node_modules");
  await cp(nodeModulesSource, join(root, "app", "node_modules"), {
    recursive: true,
    // Skip only `.cache` directories inside node_modules, never a `.cache`
    // segment in the repository path above it (e.g. a worktree under ~/.cache).
    filter: (path) => !relative(nodeModulesSource, path).split(sep).includes(".cache"),
  });
  await cp(join(packageRoot, "udev", "70-streamdeck.rules"), join(root, "share", "udev", "70-streamdeck.rules"));
  await cp(join(packageRoot, "systemd", "aiur-streamdeck.service"), join(root, "share", "systemd", "aiur-streamdeck.service"));
  await cp(join(packageRoot, "README.md"), join(root, "README.md"));
  await writeFile(join(root, "bin", "aiur-streamdeck"), "#!/bin/sh\nset -eu\nroot=$(CDPATH= cd -- \"$(dirname -- \"$0\")/..\" && pwd)\nexec \"$root/runtime/node\" \"$root/app/dist/main.js\" \"$@\"\n", { mode: 0o755 });
  await writeFile(join(root, "BUILD-INFO.json"), `${JSON.stringify({ version, commit, target, source_date_epoch: Number(sourceDateEpoch) }, null, 2)}\n`);

  const archive = join(output, `${artifactBase}.tar.gz`);
  const tarPath = join(output, `${artifactBase}.tar`);
  run("tar", ["--sort=name", `--mtime=@${sourceDateEpoch}`, "--owner=0", "--group=0", "--numeric-owner", "-C", stage, "-cf", tarPath, artifactBase]);
  run("gzip", ["-n", "-f", tarPath]);
  await rename(`${tarPath}.gz`, archive);
  const digest = await sha256(archive);
  const artifact = `${artifactBase}-${digest}.tar.gz`;
  await rename(archive, join(output, artifact));
  const manifest = {
    version,
    commit,
    target,
    sha256: digest,
    artifact,
    content_address: `releases/download/${releaseTag}/${artifact}`,
    release_asset_path: `releases/download/${releaseTag}/${artifact}`,
  };
  await writeFile(join(output, `${artifactBase}.json`), `${JSON.stringify(manifest, null, 2)}\n`);
  process.stdout.write(`${join(output, artifact)}\n`);
} finally {
  await rm(stage, { recursive: true, force: true });
}

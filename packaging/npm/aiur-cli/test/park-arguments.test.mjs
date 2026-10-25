import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

test("park requires explicit issue IDs", () => {
  const root = mkdtempSync(path.join(tmpdir(), "aiur-park-cli-"));
  const launcher = path.resolve("libexec/aiur-engine.sh");
  const releaseDir = path.join(root, "release");
  const aiur = path.join(releaseDir, "bin", "aiur");
  const epmd = path.join(releaseDir, "erts-15.0", "bin", "epmd");
  mkdirSync(path.dirname(aiur), { recursive: true });
  mkdirSync(path.dirname(epmd), { recursive: true });
  writeFileSync(aiur, '#!/usr/bin/env bash\necho "__AIUR_CONTROL_EXIT__:0"\n');
  writeFileSync(epmd, '#!/usr/bin/env bash\necho "name aiur-test at port 12345"\n');
  chmodSync(aiur, 0o755);
  chmodSync(epmd, 0o755);
  try {
    for (const args of [["park"], ["park", "--all"]]) {
      const result = spawnSync(launcher, args, {
        encoding: "utf8",
        env: { ...process.env, AIUR_RELEASE_DIR: releaseDir, AIUR_RELEASE_NODE: "aiur-test@127.0.0.1" },
      });
      expect(result.status).toBe(64);
      expect(result.stderr).toContain("park expects explicit issue IDs");
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

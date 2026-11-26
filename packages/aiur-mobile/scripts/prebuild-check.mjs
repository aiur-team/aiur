import assert from "node:assert/strict";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const scratch = join(root, ".expo");
mkdirSync(scratch, { recursive: true });
const project = mkdtempSync(join(scratch, "prebuild-"));
try {
  for (const path of ["package.json", "app.config.ts", "assets", "index.ts", "src"]) {
    cpSync(join(root, path), join(project, path), { recursive: true });
  }
  symlinkSync(join(root, "node_modules"), join(project, "node_modules"), "dir");
  const result = spawnSync(process.execPath, [
    join(root, "node_modules/expo/bin/cli"), "prebuild", "--clean", "--no-install", "--platform", "all",
  ], {
    cwd: project,
    stdio: "inherit",
    env: { ...process.env, CI: "1", EXPO_NO_TELEMETRY: "1" },
  });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, "Expo prebuild failed");
  assert.ok(existsSync(join(project, "android/app/build.gradle")), "Android project missing");
  assert.ok(existsSync(join(project, "ios/Podfile")), "iOS project missing");
  const ios = JSON.parse(readFileSync(join(project, "ios/Podfile.properties.json"), "utf8"));
  assert.equal(ios["ios.deploymentTarget"], "17.0");
  assert.match(readFileSync(join(project, "android/gradle.properties"), "utf8"), /android.minSdkVersion=29/);
  console.log("Both native projects generated with iOS 17.0 / Android API 29 minimums.");
} finally {
  rmSync(project, { recursive: true, force: true });
}

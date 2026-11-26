import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync, existsSync, chmodSync } from "node:fs";
import path from "node:path";
import { root, captureFile, setupRealLauncher, useTempRoot } from "./launcher-support.mjs";

useTempRoot();

test("Claude login adopts an already signed-in profile without starting the harness", () => {
  const { launcher } = setupRealLauncher();
  const fakeBin = path.join(root, "signed-in-bin");
  const profileDir = path.join(root, "signed-in-profile");
  const calledFile = path.join(root, "claude-called");
  const preparedReleaseDir = path.join(root, "prepared-release");
  mkdirSync(fakeBin, { recursive: true });
  mkdirSync(profileDir, { recursive: true });
  mkdirSync(path.join(preparedReleaseDir, "releases", "0.1.1"), { recursive: true });
  mkdirSync(path.join(preparedReleaseDir, "bin"), { recursive: true });
  writeFileSync(path.join(profileDir, ".claude.json"), JSON.stringify({ oauthAccount: { emailAddress: "signed-in@example.com" } }));
  writeFileSync(path.join(preparedReleaseDir, "releases", "start_erl.data"), "1 0.1.1\n");
  writeFileSync(path.join(preparedReleaseDir, "releases", "0.1.1", "vm.args"), "");
  writeFileSync(path.join(preparedReleaseDir, "releases", "0.1.1", "sys.config"), "");
  const elixir = path.join(preparedReleaseDir, "releases", "0.1.1", "elixir");
  writeFileSync(elixir, '#!/usr/bin/env bash\nprintf "%s\\nregistered\\n" "$AIUR_TEST_PROFILE"\n');
  chmodSync(elixir, 0o755);
  const aiur = path.join(preparedReleaseDir, "bin", "aiur");
  writeFileSync(aiur, "#!/usr/bin/env bash\nexit 0\n");
  chmodSync(aiur, 0o755);
  const claude = path.join(fakeBin, "claude");
  writeFileSync(claude, '#!/usr/bin/env bash\nprintf called > "$AIUR_LOGIN_CALLED"\n');
  chmodSync(claude, 0o755);

  const result = spawnSync("bash", [launcher, "login", "claude", "adopted", "--dir", profileDir], {
    encoding: "utf8",
    input: "",
    env: {
      ...process.env,
      AIUR_RELEASE_DIR: preparedReleaseDir,
      AIUR_TEST_OUT: captureFile,
      AIUR_TEST_PROFILE: profileDir,
      AIUR_LOGIN_CALLED: calledFile,
      PATH: `${fakeBin}:${process.env.PATH}`,
    },
  });

  expect(result.status).toBe(0);
  expect(result.stdout).toContain("registered claude:adopted (signed in)");
  expect(existsSync(calledFile)).toBe(false);
});

test("Claude login refuses a signed-out profile without a TTY and never starts the harness", () => {
  const { launcher, releaseDir } = setupRealLauncher();
  const fakeBin = path.join(root, "signed-out-bin");
  const profileDir = path.join(root, "signed-out-profile");
  const calledFile = path.join(root, "claude-called-signed-out");
  mkdirSync(fakeBin, { recursive: true });
  mkdirSync(profileDir, { recursive: true });
  const claude = path.join(fakeBin, "claude");
  writeFileSync(claude, '#!/usr/bin/env bash\nprintf called > "$AIUR_LOGIN_CALLED"\n');
  chmodSync(claude, 0o755);

  const result = spawnSync("bash", [launcher, "login", "claude", "signed-out", "--dir", profileDir], {
    encoding: "utf8",
    input: "",
    env: {
      ...process.env,
      AIUR_RELEASE_DIR: releaseDir,
      AIUR_TEST_OUT: captureFile,
      AIUR_TEST_PROFILE: `${profileDir}\nlogin`,
      AIUR_LOGIN_CALLED: calledFile,
      PATH: `${fakeBin}:${process.env.PATH}`,
    },
  });

  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("profile is not signed in");
  expect(result.stderr).toContain("interactive terminal");
  expect(existsSync(calledFile)).toBe(false);
});


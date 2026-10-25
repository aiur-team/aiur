import { test, expect, beforeEach, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  chmodSync,
  copyFileSync,
  cpSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const realShim = fileURLToPath(new URL("../bin/aiur.js", import.meta.url));

export const HOST_TRIPLE = {
  "darwin arm64": "darwin-arm64",
  "darwin x64": "darwin-x64",
  "linux arm64": "linux-arm64",
  "linux x64": "linux-x64",
}[`${process.platform} ${process.arch}`];
export const NODE_EXEC = spawnSync("which", ["node"], { encoding: "utf8" }).stdout.trim() || "node";

export let root;
export let captureFile;

// Builds an isolated package layout: a copy of the shim, a fake bash launcher
// that records its argv + env, the bundled conf, and (optionally) a fake
// platform package. PATH is scoped to a temp bin dir holding fake tmux/opencode.
export function setupPackage({
  withPlatformPkg = true,
  tmuxVersion = "3.4",
  withOpencode = true,
  version = "0.0.0",
} = {}) {
  mkdirSync(path.join(root, "bin"), { recursive: true });
  mkdirSync(path.join(root, "libexec"), { recursive: true });
  mkdirSync(path.join(root, "share"), { recursive: true });
  const fakeBin = path.join(root, "fakebin");
  mkdirSync(fakeBin, { recursive: true });

  copyFileSync(realShim, path.join(root, "bin", "aiur.js"));
  // The shim reads its pinned opencode version from this package.json.
  writeFileSync(
    path.join(root, "package.json"),
    JSON.stringify({ name: "aiur-cli", version, opencodeVersion: "1.17.10" }),
  );
  writeFileSync(path.join(root, "share", "aiur.tmux.conf"), "# test conf\n");

  const launcher = path.join(root, "libexec", "aiur-engine.sh");
  writeFileSync(
    launcher,
    [
      "#!/usr/bin/env bash",
      'echo "ARGS:$*" >>"$AIUR_TEST_OUT"',
      'echo "RELEASE_DIR:$AIUR_RELEASE_DIR" >>"$AIUR_TEST_OUT"',
      'echo "TMUX_CONF:$AIUR_TMUX_CONF" >>"$AIUR_TEST_OUT"',
      'if [ "${AIUR_TEST_CAPTURE_OPENCODE:-}" = 1 ]; then echo "OPENCODE_VERSION:$(opencode --version)" >>"$AIUR_TEST_OUT"; fi',
      'exit "${AIUR_TEST_EXIT:-0}"',
      "",
    ].join("\n"),
  );
  chmodSync(launcher, 0o755);

  if (withPlatformPkg) {
    const pkgDir = path.join(root, "node_modules", `aiur-cli-${HOST_TRIPLE}`);
    mkdirSync(path.join(pkgDir, "release"), { recursive: true });
    writeFileSync(
      path.join(pkgDir, "package.json"),
      JSON.stringify({ name: `aiur-cli-${HOST_TRIPLE}`, version: "0.0.0" }),
    );
  }

  if (tmuxVersion) {
    const tmux = path.join(fakeBin, "tmux");
    writeFileSync(tmux, `#!/usr/bin/env bash\necho "tmux ${tmuxVersion}"\n`);
    chmodSync(tmux, 0o755);
  }
  if (withOpencode) {
    const oc = path.join(fakeBin, "opencode");
    // Report the pinned version so the shim's pin check is satisfied.
    writeFileSync(oc, '#!/usr/bin/env bash\necho "1.17.10"\n');
    chmodSync(oc, 0o755);
  }

  return { shim: path.join(root, "bin", "aiur.js"), fakeBin };
}

export function runShim({ args = [], fakeBin, platform, arch, env = {}, forceTTY = false, cwd = root } = {}) {
  const fullEnv = {
    ...process.env,
    AIUR_TEST_OUT: captureFile,
    PATH: `${fakeBin}:${process.env.PATH}`,
    // Hermetic by default: don't fire real brew/npm during preflight tests.
    // Provisioning tests opt back in by overriding these to "".
    AIUR_SKIP_TMUX_INSTALL: "1",
    AIUR_SKIP_OPENCODE_INSTALL: "1",
    ...env,
  };
  delete fullEnv.AIUR_RELEASE_DIR;
  // Use a child wrapper to override platform/arch for a foreign host, or to fake
  // a TTY on stderr (spawnSync pipes stderr, so the update notice is otherwise
  // suppressed by the launcher's interactive gate).
  const nodeArgs =
    platform || arch || forceTTY
      ? [
          "-e",
          `if(${JSON.stringify(forceTTY)})Object.defineProperty(process.stderr,"isTTY",{value:true,configurable:true});` +
            `if(${JSON.stringify(!!platform)})Object.defineProperty(process,"platform",{value:${JSON.stringify(platform)}});` +
            `if(${JSON.stringify(!!arch)})Object.defineProperty(process,"arch",{value:${JSON.stringify(arch)}});` +
            `process.argv=[process.argv[0],${JSON.stringify(path.join(root, "bin", "aiur.js"))},${args
              .map((a) => JSON.stringify(a))
              .join(",")}];` +
            `require(${JSON.stringify(path.join(root, "bin", "aiur.js"))});`,
        ]
      : [path.join(root, "bin", "aiur.js"), ...args];
  return spawnSync(NODE_EXEC, nodeArgs, { encoding: "utf8", env: fullEnv, cwd });
}


export function setupRealLauncher() {
  const launcherSrc = fileURLToPath(new URL("../libexec/aiur-engine.sh", import.meta.url));
  mkdirSync(path.join(root, "libexec"), { recursive: true });
  const launcher = path.join(root, "libexec", "aiur-engine.sh");
  copyFileSync(launcherSrc, launcher);
  for (const name of ["aiur-daemon-supervisor.sh", "aiur-queue.sh", "aiur-epic.sh", "aiur-feature.sh", "aiur-capabilities.sh", "aiur-experiments.sh", "aiur-executor-session.sh", "engine"])
    cpSync(path.join(path.dirname(launcherSrc), name), path.join(root, "libexec", name), { recursive: true });
  const releaseDir = path.join(root, "release");
  const vsn = "0.1.1";
  const vsnDir = path.join(releaseDir, "releases", vsn);
  mkdirSync(vsnDir, { recursive: true });
  mkdirSync(path.join(releaseDir, "lib"), { recursive: true });
  const binAiur = path.join(releaseDir, "bin", "aiur");
  mkdirSync(path.dirname(binAiur), { recursive: true });
  writeFileSync(binAiur, "#!/usr/bin/env bash\nexit 0\n");
  chmodSync(binAiur, 0o755);
  writeFileSync(path.join(releaseDir, "releases", "start_erl.data"), `1 ${vsn}\n`);
  writeFileSync(path.join(vsnDir, "vm.args"), "");
  writeFileSync(path.join(vsnDir, "sys.config"), "");

  const elixir = path.join(vsnDir, "elixir");
  writeFileSync(
    elixir,
    [
      "#!/usr/bin/env bash",
      'echo "ELIXIR_ARGS:$*" >>"$AIUR_TEST_OUT"',
      'echo "ARGV_FILE:$(cat "$AIUR_ARGV_FILE")" >>"$AIUR_TEST_OUT"',
      'echo "DEEPSEEK_API_KEY:${DEEPSEEK_API_KEY:-}" >>"$AIUR_TEST_OUT"',
      'echo "OPENROUTER_API_KEY:${OPENROUTER_API_KEY:-}" >>"$AIUR_TEST_OUT"',
      'echo "MOONSHOT_API_KEY:${MOONSHOT_API_KEY:-}" >>"$AIUR_TEST_OUT"',
      'if [ -n "${AIUR_TEST_PROFILE:-}" ]; then printf "%s" "$AIUR_TEST_PROFILE"; fi',
      "exit 0",
      "",
    ].join("\n"),
  );
  chmodSync(elixir, 0o755);

  return { launcher, releaseDir };
}

// Registers the per-test temp package root; call once at the top of a test file.
export function useTempRoot() {
  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), "aiur-shim-"));
    captureFile = path.join(root, "capture.txt");
  });
  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
  });
}

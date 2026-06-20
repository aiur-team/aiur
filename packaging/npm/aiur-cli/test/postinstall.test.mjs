import { test, expect } from "bun:test";
import {
  provisionOpencode,
  OPENCODE_PACKAGE,
  opencodeInstallSpec,
  provisionTmux,
  tmuxSatisfiesMin,
  MIN_TMUX,
} from "../scripts/postinstall.mjs";

test("opencode is pinned to a specific version, not floating to latest", () => {
  // 1.17.x broke aiur's chat panes; the package spec must carry an explicit
  // version so a fresh install gets the validated one.
  expect(OPENCODE_PACKAGE).toMatch(/^opencode-ai@\d+\.\d+\.\d+$/);
});

test("skips the install when AIUR_SKIP_OPENCODE_INSTALL=1", () => {
  let installed = false;
  const result = provisionOpencode({
    env: { AIUR_SKIP_OPENCODE_INSTALL: "1" },
    isPresent: () => false,
    install: () => {
      installed = true;
      return true;
    },
    log: () => {},
  });

  expect(result).toBe("skipped:disabled");
  expect(installed).toBe(false);
});

test("skips the install when opencode already resolves on PATH", () => {
  let installed = false;
  const result = provisionOpencode({
    env: {},
    isPresent: () => true,
    install: () => {
      installed = true;
      return true;
    },
    log: () => {},
  });

  expect(result).toBe("skipped:present");
  expect(installed).toBe(false);
});

test("installs opencode when it is missing", () => {
  let installed = false;
  const result = provisionOpencode({
    env: {},
    isPresent: () => false,
    install: () => {
      installed = true;
      return true;
    },
    log: () => {},
  });

  expect(result).toBe("installed");
  expect(installed).toBe(true);
});

test("a failed install prints a manual hint and does not throw", () => {
  const logs = [];
  const result = provisionOpencode({
    env: {},
    isPresent: () => false,
    install: () => false,
    log: (message) => logs.push(message),
  });

  expect(result).toBe("failed");
  expect(logs.some((line) => line.includes("npm install -g opencode-ai"))).toBe(true);
});

test("opencodeInstallSpec forces online and strips inherited offline npm config", () => {
  // Regression: an outer `npm install -g --offline` (CI smoke, a corporate
  // mirror, prefer-offline configs) exports npm_config_offline to lifecycle
  // scripts; the nested opencode install must NOT inherit it or it dies with
  // ENOTCACHED on a cold cache and silently leaves opencode unprovisioned.
  const spec = opencodeInstallSpec({
    npm_config_offline: "true",
    npm_config_prefer_offline: "true",
    PATH: "/usr/bin",
  });

  // Inherited offline flags are stripped from the child env…
  expect(spec.env.npm_config_offline).toBeUndefined();
  expect(spec.env.npm_config_prefer_offline).toBeUndefined();
  // …unrelated env is preserved…
  expect(spec.env.PATH).toBe("/usr/bin");
  // …and the CLI flags force online (CLI config outranks any env that slips through).
  expect(spec.command).toBe("npm");
  expect(spec.args).toContain("--no-offline");
  expect(spec.args).toContain("--no-prefer-offline");
  expect(spec.args).toContain(OPENCODE_PACKAGE);
});

// --- tmux provisioning ------------------------------------------------------

test("MIN_TMUX matches the launcher preflight floor (>= 3.3)", () => {
  expect(MIN_TMUX).toEqual([3, 3]);
});

test("tmuxSatisfiesMin accepts a new-enough tmux and rejects an old/absent one", () => {
  const ver = (stdout) => () => ({ status: 0, stdout });
  expect(tmuxSatisfiesMin(ver("tmux 3.4"))).toBe(true);
  expect(tmuxSatisfiesMin(ver("tmux 3.3"))).toBe(true);
  expect(tmuxSatisfiesMin(ver("tmux 4.0"))).toBe(true);
  expect(tmuxSatisfiesMin(ver("tmux 3.2a"))).toBe(false);
  expect(tmuxSatisfiesMin(ver("tmux 2.9"))).toBe(false);
  // Not installed: spawnSync surfaces ENOENT as result.error.
  expect(tmuxSatisfiesMin(() => ({ error: new Error("ENOENT") }))).toBe(false);
});

test("tmux: skips the install when AIUR_SKIP_TMUX_INSTALL=1", () => {
  let installed = false;
  const result = provisionTmux({
    env: { AIUR_SKIP_TMUX_INSTALL: "1" },
    isPresent: () => false,
    install: () => {
      installed = true;
      return true;
    },
    log: () => {},
  });

  expect(result).toBe("skipped:disabled");
  expect(installed).toBe(false);
});

test("tmux: skips the install when a new-enough tmux already resolves", () => {
  let installed = false;
  const result = provisionTmux({
    env: {},
    isPresent: () => true,
    install: () => {
      installed = true;
      return true;
    },
    log: () => {},
  });

  expect(result).toBe("skipped:present");
  expect(installed).toBe(false);
});

test("tmux: installs when missing", () => {
  let installed = false;
  const result = provisionTmux({
    env: {},
    isPresent: () => false,
    install: () => {
      installed = true;
      return true;
    },
    log: () => {},
  });

  expect(result).toBe("installed");
  expect(installed).toBe(true);
});

test("tmux: a failed install prints a platform-appropriate hint and does not throw", () => {
  const macLogs = [];
  const macResult = provisionTmux({
    env: {},
    isPresent: () => false,
    install: () => false,
    platform: "darwin",
    log: (message) => macLogs.push(message),
  });
  expect(macResult).toBe("failed");
  expect(macLogs.some((line) => line.includes("brew install tmux"))).toBe(true);

  const linuxLogs = [];
  const linuxResult = provisionTmux({
    env: {},
    isPresent: () => false,
    install: () => false,
    platform: "linux",
    log: (message) => linuxLogs.push(message),
  });
  expect(linuxResult).toBe("failed");
  expect(linuxLogs.some((line) => line.includes("apt install tmux"))).toBe(true);
});

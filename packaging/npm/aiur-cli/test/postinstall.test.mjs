import { test, expect } from "bun:test";
import { provisionOpencode, OPENCODE_PACKAGE } from "../scripts/postinstall.mjs";

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

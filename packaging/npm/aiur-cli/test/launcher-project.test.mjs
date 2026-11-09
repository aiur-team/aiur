import { test, expect } from "bun:test";
import { existsSync, rmSync } from "node:fs";
import { captureFile, useTempRoot } from "./launcher-support.mjs";
import { registry, runRemoteEngine, setupRemoteLauncher, startServer, successBody } from "./launcher-remote-support.mjs";

useTempRoot();

const b64 = (text) => Buffer.from(text).toString("base64");

function withServer(fn) {
  const server = startServer({ body: successBody() });
  try {
    return fn(server, setupRemoteLauncher(registry(server.url)));
  } finally {
    server.stop();
  }
}

test("--project after the selector and after the command both send project: and no project_hint", () => {
  withServer((server, setup) => {
    for (const args of [
      ["--instance", "t", "--project", "o/b", "queue", "show"],
      ["--instance", "t", "queue", "show", "--project", "o/b"],
      ["--instance", "t", "queue", "show", "--project=o/b"],
    ]) {
      const result = runRemoteEngine(setup, args);
      expect(result.status).toBe(0);
      const expression = server.requests().at(-1).body.expression;
      expect(expression).toContain(`project: Base.decode64!("${b64("o/b")}")`);
      expect(expression).not.toContain("project_hint");
      expect(expression).not.toContain("--project");
    }
  });
});

test("a remote call without --project carries no project keyword", () => {
  withServer((server, setup) => {
    expect(runRemoteEngine(setup, ["--instance", "t", "queue", "show"]).status).toBe(0);
    expect(server.requests().at(-1).body.expression).not.toContain("project");
  });
});

test("a gateway-scoped command refuses --project before any request", () => {
  withServer((server, setup) => {
    rmSync(captureFile, { force: true });
    const result = runRemoteEngine(setup, ["--instance", "t", "--project", "o/b", "status"]);
    expect(result.status).toBe(64);
    expect(result.stderr).toContain("--project does not apply");
    expect(server.requests()).toHaveLength(0);
    expect(existsSync(captureFile)).toBe(false);
  });
});

test("a malformed --project and --instance all are refused", () => {
  withServer((server, setup) => {
    const bad = runRemoteEngine(setup, ["--instance", "t", "queue", "show", "--project", "foo"]);
    expect(bad.status).toBe(64);
    expect(bad.stderr).toContain("--project expects owner/repo");

    const all = runRemoteEngine(setup, ["--instance", "all", "--project", "o/b", "queue", "show"]);
    expect(all.status).toBe(64);
    expect(all.stderr).toContain("cannot be used with 'all'");
    expect(server.requests()).toHaveLength(0);
  });
});

test("remote set sends project and no caller_cwd", () => {
  withServer((server, setup) => {
    expect(runRemoteEngine(setup, ["--instance", "t", "set", "agent.routing", '"x"', "--project", "o/b"]).status).toBe(0);
    const expression = server.requests().at(-1).body.expression;
    expect(expression).toContain(`project: Base.decode64!("${b64("o/b")}")`);
    expect(expression).toContain("caller_agent_workspace_env:");
    expect(expression).not.toContain("caller_cwd");
  });
});

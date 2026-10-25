import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { root, useTempRoot } from "./launcher-support.mjs";
import {
  runRemote,
  setupRemoteLauncher,
  startServer,
  successBody,
} from "./launcher-remote-support.mjs";

useTempRoot();

const readFixture = JSON.parse(
  readFileSync(new URL("./fixtures/control-read-commands.json", import.meta.url), "utf8"),
);

function registry(instances) {
  const rows = Object.entries(instances).flatMap(([name, url]) => [
    `  ${name}:`,
    `    url: ${url}`,
    "    token_env: AIUR_TOKEN_T",
  ]);
  return ["version: 1", "instances:", ...rows, ""].join("\n");
}

test("the shared read fixture is accepted for all without drifting from emitted expressions", () => {
  const server = startServer({ body: successBody("fixture\n__AIUR_CONTROL_EXIT__:0\n") });
  try {
    const setup = setupRemoteLauncher(registry({ only: server.url }));
    for (const command of readFixture.commands) {
      const before = server.requests().length;
      const result = runRemote(setup, ["--instance", "all", ...command.argv], {
        AIUR_AGENT_WORKSPACE: "",
      });
      expect(result.status, command.argv.join(" ")).toBe(0);
      expect(server.requests(), command.argv.join(" ")).toHaveLength(before + 1);
      expect(server.requests().at(-1).body.expression).toBe(command.expression);
      expect(server.requests().at(-1).body.max_scope).toBe("read");
    }
  } finally {
    server.stop();
  }
}, 60_000);

test("two live instances run concurrently and print one labeled block each", () => {
  const barrierFile = path.join(root, "fanout-barrier");
  const pc = startServer({
    name: "pc",
    body: successBody("pc agents\n__AIUR_CONTROL_EXIT__:0\n"),
    barrierFile,
    barrierCount: 2,
  });
  const nuc = startServer({
    name: "nuc",
    body: successBody("nuc agents\n__AIUR_CONTROL_EXIT__:0\n"),
    barrierFile,
    barrierCount: 2,
  });
  try {
    const setup = setupRemoteLauncher(registry({ pc: pc.url, nuc: nuc.url }));
    const result = runRemote(setup, ["--instance", "all", "agents"]);
    expect(result.status).toBe(0);
    expect(result.stdout).toContain(`== pc (${new URL(pc.url).host}) ==\npc agents`);
    expect(result.stdout).toContain(`== nuc (${new URL(nuc.url).host}) ==\nnuc agents`);
    expect(result.stdout.indexOf("== pc")).toBeLessThan(result.stdout.indexOf("== nuc"));
    expect(pc.requests()).toHaveLength(1);
    expect(nuc.requests()).toHaveLength(1);
    expect(pc.requests()[0].body.max_scope).toBe("read");
    expect(nuc.requests()[0].body.max_scope).toBe("read");
  } finally {
    pc.stop();
    nuc.stop();
  }
}, 20_000);

test("an unreachable instance remains visible and makes the aggregate fail", () => {
  const pc = startServer({ name: "pc", body: successBody("pc live\n__AIUR_CONTROL_EXIT__:0\n") });
  try {
    const setup = setupRemoteLauncher(registry({ pc: pc.url, nuc: "http://127.0.0.1:1" }));
    const result = runRemote(setup, ["--instance", "all", "agents"]);
    expect(result.status).toBe(69);
    expect(result.stdout).toContain(`== pc (${new URL(pc.url).host}) ==\npc live`);
    expect(result.stdout).toContain("== nuc == unreachable: could not reach remote instance 'nuc'");
    expect(result.stdout.match(/^== pc/gm)).toHaveLength(1);
    expect(result.stdout.match(/^== nuc/gm)).toHaveLength(1);
    expect(pc.requests()).toHaveLength(1);
  } finally {
    pc.stop();
  }
});

test("JSON mode emits one envelope per instance without parsing remote output", () => {
  const pc = startServer({ name: "pc", body: successBody('{"rows":["pc"]}\n__AIUR_CONTROL_EXIT__:0\n') });
  const nuc = startServer({ name: "nuc", body: successBody('{"rows":["nuc"]}\n__AIUR_CONTROL_EXIT__:0\n') });
  try {
    const setup = setupRemoteLauncher(registry({ pc: pc.url, nuc: nuc.url }));
    const result = runRemote(setup, ["--instance", "all", "agents", "--json"]);
    expect(result.status).toBe(0);
    const lines = result.stdout.trim().split("\n").map((line) => JSON.parse(line));
    expect(lines).toEqual([
      { instance: "pc", ok: true, exit_code: 0, output: '{"rows":["pc"]}' },
      { instance: "nuc", ok: true, exit_code: 0, output: '{"rows":["nuc"]}' },
    ]);
    expect(pc.requests()[0].body.max_scope).toBe("read");
    expect(nuc.requests()[0].body.max_scope).toBe("read");
  } finally {
    pc.stop();
    nuc.stop();
  }
});

test("JSON mode keeps an unreachable instance as an error envelope", () => {
  const pc = startServer({ name: "pc", body: successBody("pc live\n__AIUR_CONTROL_EXIT__:0\n") });
  try {
    const setup = setupRemoteLauncher(registry({ pc: pc.url, nuc: "http://127.0.0.1:1" }));
    const result = runRemote(setup, ["--instance", "all", "agents", "--json"]);
    expect(result.status).toBe(69);
    const lines = result.stdout.trim().split("\n").map((line) => JSON.parse(line));
    expect(lines[0]).toEqual({ instance: "pc", ok: true, exit_code: 0, output: "pc live" });
    expect(lines[1]).toMatchObject({ instance: "nuc", ok: false, error: "unreachable" });
    expect(lines[1].detail).toContain("could not reach remote instance 'nuc'");
  } finally {
    pc.stop();
  }
});

test("write commands are refused before any fan-out request", () => {
  const server = startServer({ body: successBody("wrong\n__AIUR_CONTROL_EXIT__:0\n") });
  try {
    const setup = setupRemoteLauncher(registry({ only: server.url }));
    for (const args of [
      ["pause"],
      ["alerts", "ack", "ticket.1.agent.attention.test"],
      ["queue", "add", "1"],
      ["queue", "order", "team", "--to", "0"],
      ["epic", "set", "demo", "1", "--as", "operator"],
      ["feature", "create", "demo", "--label", "Demo"],
      ["experiments", "freeze"],
      ["executor-sweep", "--apply"],
      ["watch", "--changes"],
      ["message", "1", "hello"],
      ["executor-wait", "--as", "operator"],
    ]) {
      const result = runRemote(setup, ["--instance", "all", ...args]);
      expect(result.status).toBe(64);
      expect(result.stderr).toContain("--instance all is for read commands");
    }
    expect(server.requests()).toHaveLength(0);

    expect(runRemote(setup, ["--instance", "all", "alerts"]).status).toBe(0);
    expect(server.requests()).toHaveLength(1);
  } finally {
    server.stop();
  }
}, 20_000);

test("the reserved all name is rejected as a registry entry", () => {
  const server = startServer({ body: successBody("wrong\n__AIUR_CONTROL_EXIT__:0\n") });
  try {
    const setup = setupRemoteLauncher(registry({ all: server.url }));
    const result = runRemote(setup, ["--instance", "all", "agents"]);
    expect(result.status).toBe(64);
    expect(result.stderr).toContain("instance name all is reserved");
    expect(server.requests()).toHaveLength(0);
  } finally {
    server.stop();
  }
});

test("the aggregate returns the highest live command exit code", () => {
  const pc = startServer({ name: "pc", body: successBody("pc failed\n__AIUR_CONTROL_EXIT__:3\n") });
  const nuc = startServer({ name: "nuc", body: successBody("nuc failed\n__AIUR_CONTROL_EXIT__:7\n") });
  try {
    const setup = setupRemoteLauncher(registry({ pc: pc.url, nuc: nuc.url }));
    const result = runRemote(setup, ["--instance", "all", "agents"]);
    expect(result.status).toBe(7);
    expect(result.stdout).toContain("pc failed");
    expect(result.stdout).toContain("nuc failed");
  } finally {
    pc.stop();
    nuc.stop();
  }
});

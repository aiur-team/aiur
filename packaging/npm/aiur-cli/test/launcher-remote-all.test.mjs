import { test, expect } from "bun:test";
import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
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

test("fleet executor wait defers acknowledgement and persists one cursor per instance", () => {
  const pc = startServer({ name: "pc", body: { ...successBody('{"status":"timeout","role":"owner","records":[]}\n__AIUR_CONTROL_EXIT__:0\n'), instance_id: "run/pc" } });
  const nuc = startServer({ name: "nuc", body: { ...successBody('{"status":"woken","role":"owner","records":[{"wake_id":41},{"wake_id":44}]}\n__AIUR_CONTROL_EXIT__:0\n'), instance_id: "run/nuc" } });
  try {
    const setup = setupRemoteLauncher(registry({ pc: pc.url, nuc: nuc.url }));
    const result = runRemote(setup, ["--instance", "all", "executor-wait", "--timeout", "1", "--as", "fleet-executor", "--json"]);
    expect(result.status).toBe(0);
    expect(result.stderr).toContain('"instance":"nuc"');
    expect(result.stderr).toContain('"wake_id":44');
    for (const server of [pc, nuc]) {
      const request = server.requests()[0];
      expect(request.body.max_scope).toBe("write");
      expect(request.body.expression).toContain("timeout_ms: 1000");
      expect(request.body.expression).toContain("defer_ack: true");
      expect(request.body.expression).toContain("ack_through: 0");
      expect(request.body.expression).toContain('as: "fleet-executor"');
      expect(request.body).not.toHaveProperty("env");
    }
    const cursor = readFileSync(path.join(setup.home, ".aiur/remote-state/nuc.wake-ack"), "utf8");
    expect(cursor).toBe("run/nuc\t44\n");
    expect(readFileSync(path.join(setup.home, ".aiur/remote-state/pc.wake-ack"), "utf8")).toBe("run/pc\t0\n");
  } finally { pc.stop(); nuc.stop(); }
});

test("fleet wait requires --as and caps remote waits at ten minutes", () => {
  const setup = setupRemoteLauncher(registry({ t: "http://127.0.0.1:1" }));
  const missing = runRemote(setup, ["--instance", "all", "executor-wait", "--timeout", "1"]);
  expect(missing.status).toBe(64);
  expect(missing.stderr).toContain("requires --as <id>");
  const tooLong = runRemote(setup, ["--instance", "all", "executor-wait", "--timeout", "601", "--as", "fleet"]);
  expect(tooLong.status).toBe(64);
  expect(tooLong.stderr).toContain("cannot exceed 600 seconds");
});

test("not_owner acknowledge failures stay errors and preserve that instance cursor", () => {
  const server = startServer({ name: "nuc", body: { ...successBody('{"status":"error","stage":"acknowledge","role":"observer","records":[],"detail":"not_owner"}\n__AIUR_CONTROL_EXIT__:1\n'), instance_id: "run/nuc" } });
  try {
    const setup = setupRemoteLauncher(registry({ nuc: server.url }));
    const cursorPath = path.join(setup.home, ".aiur/remote-state/nuc.wake-ack");
    mkdirSync(path.dirname(cursorPath), { recursive: true });
    writeFileSync(cursorPath, "run/nuc\t44\n");
    const result = runRemote(setup, ["--instance", "all", "executor-wait", "--timeout", "1", "--as", "fleet", "--json"]);
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('"status":"error"');
    expect(result.stderr).toContain("not_owner");
    expect(result.stderr).not.toContain("wake cursor reset");
    expect(readFileSync(cursorPath, "utf8")).toBe("run/nuc\t44\n");
  } finally { server.stop(); }
});

test("colliding wake ids advance each instance cursor independently", () => {
  const pc = startServer({ name: "pc", body: { ...successBody('{"status":"woken","role":"owner","records":[{"wake_id":3}]}\n__AIUR_CONTROL_EXIT__:0\n'), instance_id: "run/pc" } });
  const nuc = startServer({ name: "nuc", body: { ...successBody('{"status":"woken","role":"owner","records":[{"wake_id":3},{"wake_id":44}]}\n__AIUR_CONTROL_EXIT__:0\n'), instance_id: "run/nuc" } });
  try {
    const setup = setupRemoteLauncher(registry({ pc: pc.url, nuc: nuc.url }));
    const result = runRemote(setup, ["--instance", "all", "executor-wait", "--timeout", "1", "--as", "fleet", "--json"]);
    expect(result.status).toBe(0);
    expect(readFileSync(path.join(setup.home, ".aiur/remote-state/pc.wake-ack"), "utf8")).toBe("run/pc\t3\n");
    expect(readFileSync(path.join(setup.home, ".aiur/remote-state/nuc.wake-ack"), "utf8")).toBe("run/nuc\t44\n");
  } finally { pc.stop(); nuc.stop(); }
});

test("text-mode fleet wakes include the instance prefix", () => {
  const server = startServer({ name: "nuc", body: { ...successBody('{"status":"woken","role":"owner","records":[{"wake_id":41}]}\n__AIUR_CONTROL_EXIT__:0\n'), instance_id: "run/nuc" } });
  try {
    const setup = setupRemoteLauncher(registry({ nuc: server.url }));
    const result = runRemote(setup, ["--instance", "all", "executor-wait", "--timeout", "1", "--as", "fleet"]);
    expect(result.status).toBe(0);
    expect(result.stderr).toContain('[nuc] {"wake_id":41}');
  } finally { server.stop(); }
});

test("cancelling the idle remote wait leaves no curl or request files", () => {
  const pidFile = path.join(root, "curl.pid");
  const pc = startServer({ name: "pc", body: successBody('{"status":"timeout","role":"owner","records":[]}\n__AIUR_CONTROL_EXIT__:0\n'), delayMs: 15_000 });
  const nuc = startServer({ name: "nuc", body: { ...successBody('{"status":"woken","role":"owner","records":[{"wake_id":9}]}\n__AIUR_CONTROL_EXIT__:0\n'), instance_id: "run/nuc" } });
  try {
    const setup = setupRemoteLauncher(registry({ pc: pc.url, nuc: nuc.url }));
    const curlPath = spawnSync("which", ["curl"], { encoding: "utf8" }).stdout.trim();
    writeFileSync(path.join(setup.fakeBin, "curl"), `#!/usr/bin/env bash\nprintf '%s' "$$" >'${pidFile}'\nexec '${curlPath}' "$@"\n`);
    chmodSync(path.join(setup.fakeBin, "curl"), 0o755);
    const tmpdir = path.join(root, "remote-tmp");
    mkdirSync(tmpdir, { recursive: true });
    const result = runRemote(setup, ["--instance", "all", "executor-wait", "--timeout", "10", "--as", "fleet", "--json"], { TMPDIR: tmpdir });
    expect(result.status).toBe(0);
    const remaining = readdirSync(tmpdir);
    expect(remaining).toEqual([]);
    if (existsSync(pidFile)) {
      const pid = readFileSync(pidFile, "utf8");
      const state = spawnSync("ps", ["-o", "stat=", "-p", pid], { encoding: "utf8" }).stdout.trim();
      expect(state === "" || state.startsWith("Z")).toBe(true);
    }
  } finally { pc.stop(); nuc.stop(); }
}, 20_000);

test("a named remote executor wait uses that instance's cursor", () => {
  const server = startServer({ name: "nuc", body: { ...successBody('{"status":"timeout","role":"owner","records":[]}\n__AIUR_CONTROL_EXIT__:0\n'), instance_id: "run/nuc" } });
  try {
    const setup = setupRemoteLauncher(registry({ nuc: server.url }));
    const result = runRemote(setup, ["--instance", "nuc", "executor-wait", "--timeout", "1", "--as", "fleet", "--json"]);
    expect(result.status).toBe(0);
    expect(server.requests()).toHaveLength(1);
    expect(server.requests()[0].body.expression).toContain("ack_through: 0");
    expect(readFileSync(path.join(setup.home, ".aiur/remote-state/nuc.wake-ack"), "utf8")).toBe("run/nuc\t0\n");
  } finally { server.stop(); }
});

test("idle instances each report timeout", () => {
  const pc = startServer({ name: "pc", body: successBody('{"status":"timeout","role":"owner","records":[]}\n__AIUR_CONTROL_EXIT__:0\n') });
  const nuc = startServer({ name: "nuc", body: successBody('{"status":"timeout","role":"owner","records":[]}\n__AIUR_CONTROL_EXIT__:0\n') });
  try {
    const setup = setupRemoteLauncher(registry({ pc: pc.url, nuc: nuc.url }));
    const result = runRemote(setup, ["--instance", "all", "executor-wait", "--timeout", "1", "--as", "fleet", "--json"]);
    expect(result.status).toBe(0);
    expect(result.stderr).toContain('{"instance":"pc","status":"timeout"');
    expect(result.stderr).toContain('{"instance":"nuc","status":"timeout"');
  } finally { pc.stop(); nuc.stop(); }
});

test("an unreachable instance is reported while another delivers", () => {
  const nuc = startServer({ name: "nuc", body: successBody('{"status":"woken","role":"owner","records":[{"wake_id":9}]}\n__AIUR_CONTROL_EXIT__:0\n') });
  try {
    const setup = setupRemoteLauncher(registry({ pc: "http://127.0.0.1:1", nuc: nuc.url }));
    const result = runRemote(setup, ["--instance", "all", "executor-wait", "--timeout", "1", "--as", "fleet", "--json"]);
    expect(result.status).toBe(69);
    expect(result.stderr).toContain('"instance":"nuc"');
    expect(result.stderr).toContain('"wake_id":9');
    expect(result.stderr).toContain('"instance":"pc","status":"error"');
  } finally { nuc.stop(); }
});

test("unsupported deferred acknowledgement is reported and never retried without its options", () => {
  const old = startServer({ name: "old", status: 422, body: { error: { reason: "unknown_on_build", detail: "defer_ack" } } });
  try {
    const setup = setupRemoteLauncher(registry({ old: old.url }));
    for (let attempt = 0; attempt < 2; attempt++) {
      const result = runRemote(setup, ["--instance", "all", "executor-wait", "--timeout", "1", "--as", "fleet", "--json"]);
      expect(result.status).toBe(0);
      expect(result.stderr).toContain('"status":"unsupported"');
    }
    expect(old.requests()).toHaveLength(2);
    for (const request of old.requests()) expect(request.body.expression).toContain("defer_ack: true");
  } finally { old.stop(); }
});

test("journal reset clears the stored cursor and warns", () => {
  const server = startServer({ name: "nuc", body: { ...successBody('{"status":"error","stage":"acknowledge","role":"owner","records":[],"detail":"journal_reset"}\n__AIUR_CONTROL_EXIT__:1\n'), instance_id: "run/nuc" } });
  try {
    const setup = setupRemoteLauncher(registry({ nuc: server.url }));
    const cursorPath = path.join(setup.home, ".aiur/remote-state/nuc.wake-ack");
    mkdirSync(path.dirname(cursorPath), { recursive: true });
    writeFileSync(cursorPath, "run/nuc\t44\n");
    const result = runRemote(setup, ["--instance", "all", "executor-wait", "--timeout", "1", "--as", "fleet", "--json"]);
    expect(result.status).toBe(0);
    expect(server.requests()[0].body.expression).toContain("ack_through: 44");
    expect(result.stderr).toContain("wake cursor reset for nuc");
    expect(readFileSync(cursorPath, "utf8")).toBe("run/nuc\t0\n");
  } finally { server.stop(); }
});

test("a changed server instance id clears its prior cursor", () => {
  const server = startServer({ name: "nuc", body: { ...successBody('{"status":"timeout","role":"owner","records":[]}\n__AIUR_CONTROL_EXIT__:0\n'), instance_id: "run/new" } });
  try {
    const setup = setupRemoteLauncher(registry({ nuc: server.url }));
    const cursorPath = path.join(setup.home, ".aiur/remote-state/nuc.wake-ack");
    mkdirSync(path.dirname(cursorPath), { recursive: true });
    writeFileSync(cursorPath, "run/old\t44\n");
    const result = runRemote(setup, ["--instance", "all", "executor-wait", "--timeout", "1", "--as", "fleet", "--json"]);
    expect(result.status).toBe(0);
    expect(server.requests()[0].body.expression).toContain("ack_through: 44");
    expect(result.stderr).toContain("wake cursor reset for nuc");
    expect(readFileSync(cursorPath, "utf8")).toBe("run/new\t0\n");
  } finally { server.stop(); }
});

test("a later fleet wait acknowledges only the previous batch for that instance", () => {
  const firstBody = { ...successBody('{"status":"woken","role":"owner","records":[{"wake_id":41},{"wake_id":44}]}\n__AIUR_CONTROL_EXIT__:0\n'), instance_id: "test/t" };
  const secondBody = { ...successBody('{"status":"timeout","role":"owner","records":[]}\n__AIUR_CONTROL_EXIT__:0\n'), instance_id: "test/t" };
  const handler = path.join(root, "fleet-response.mjs");
  writeFileSync(handler, `export default (_request, count) => ({body: ${JSON.stringify(firstBody)}, ...(count > 1 ? {body: ${JSON.stringify(secondBody)}} : {})});`);
  const nuc = startServer({ name: "nuc", body: secondBody, onRequest: handler });
  try {
    const setup = setupRemoteLauncher(registry({ nuc: nuc.url }));
    const stableHome = path.join(root, "fleet-home");
    mkdirSync(path.join(stableHome, ".aiur"), { recursive: true });
    writeFileSync(path.join(stableHome, ".aiur", "remote-instances.yaml"), readFileSync(path.join(setup.home, ".aiur", "remote-instances.yaml"), "utf8"));
    const first = runRemote(setup, ["--instance", "all", "executor-wait", "--timeout", "1", "--as", "fleet", "--json"], { HOME: stableHome });
    expect(first.status).toBe(0);
    const second = runRemote(setup, ["--instance", "all", "executor-wait", "--timeout", "1", "--as", "fleet", "--json"], { HOME: stableHome });
    expect(second.status).toBe(0);
    expect(nuc.requests()[0].body.expression).toContain("ack_through: 0");
    expect(nuc.requests()[1].body.expression).toContain("ack_through: 44");
  } finally { nuc.stop(); }
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

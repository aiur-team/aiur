import { test, expect } from "bun:test";
import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { root, useTempRoot } from "./launcher-support.mjs";
import { registry, runRemote, setupRemoteLauncher, startServer, successBody } from "./launcher-remote-support.mjs";

useTempRoot();

const UUID_V7 = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const GIVEN = "018f0000-0000-7000-8000-0000000000aa";

function withServer(options, run) {
  const server = startServer(options);
  try {
    return run(server, setupRemoteLauncher(registry(server.url)));
  } finally {
    server.stop();
  }
}

test("a remote write sends contract 2 and a generated UUIDv7 request id", () => {
  withServer({ body: successBody() }, (server, setup) => {
    expect(runRemote(setup, ["--instance", "t", "pause"]).status).toBe(0);
    const { body } = server.requests()[0];
    expect(body.contract_version).toBe(2);
    expect(body.request_id).toMatch(UUID_V7);
  });
});

test("--request-id and AIUR_REQUEST_ID are sent verbatim and bad ids are refused", () => {
  withServer({ body: successBody() }, (server, setup) => {
    expect(runRemote(setup, ["--instance", "t", "--request-id", GIVEN, "pause"]).status).toBe(0);
    expect(runRemote(setup, ["--request-id=" + GIVEN, "--instance=t", "pause"]).status).toBe(0);
    expect(runRemote(setup, ["--instance", "t", "pause"], { AIUR_REQUEST_ID: GIVEN }).status).toBe(0);
    expect(server.requests().map((r) => r.body.request_id)).toEqual([GIVEN, GIVEN, GIVEN]);

    const bad = runRemote(setup, ["--instance", "t", "--request-id", "nope", "pause"]);
    expect(bad.status).toBe(64);
    expect(bad.stderr).toContain("--request-id must be a UUIDv7");
    expect(server.requests()).toHaveLength(3);
  });
});

test("--request-id cannot be combined with --instance all", () => {
  withServer({ body: successBody() }, (server, setup) => {
    const result = runRemote(setup, ["--instance", "all", "--request-id", GIVEN, "status"]);
    expect(result.status).toBe(64);
    expect(result.stderr).toContain("--request-id cannot be combined with --instance all");
    expect(server.requests()).toHaveLength(0);
  });
});

test("a 504 exits 124 and names the id that is safe to retry", () => {
  withServer({ status: 504, body: { error: { code: "timeout", timeout_ms: 10_000 } } }, (_server, setup) => {
    const result = runRemote(setup, ["--instance", "t", "--request-id", GIVEN, "pause"]);
    expect(result.status).toBe(124);
    expect(result.stderr).toContain(`retry with --request-id ${GIVEN} is safe`);
  });
});

test("a lost connection (curl timeout) exits 124 with the retry hint instead of 'could not reach'", () => {
  withServer({ body: successBody() }, (_server, setup) => {
    const stubs = path.join(root, "curl-stub");
    mkdirSync(stubs, { recursive: true });
    writeFileSync(path.join(stubs, "curl"), "#!/usr/bin/env bash\nexit 28\n");
    chmodSync(path.join(stubs, "curl"), 0o755);
    const env = { PATH: `${stubs}:${setup.fakeBin}:${process.env.PATH}` };
    const result = runRemote(setup, ["--instance", "t", "--request-id", GIVEN, "pause"], env);
    expect(result.status).toBe(124);
    expect(result.stderr).toContain(`retry with --request-id ${GIVEN} is safe`);
    expect(result.stderr).not.toContain("could not reach");
  });
});

test("409 request_in_progress exits 75 and outcome_unknown exits 124 asking for a new id", () => {
  withServer({ status: 409, body: { error: { code: "request_in_progress" } } }, (_server, setup) => {
    const result = runRemote(setup, ["--instance", "t", "--request-id", GIVEN, "pause"]);
    expect(result.status).toBe(75);
    expect(result.stderr).toContain("still running");
    expect(result.stderr).toContain(GIVEN);
  });
  withServer({ name: "unknown", status: 409, body: { error: { code: "outcome_unknown" } } }, (_server, setup) => {
    const result = runRemote(setup, ["--instance", "t", "--request-id", GIVEN, "pause"]);
    expect(result.status).toBe(124);
    expect(result.stderr).toContain("use a new id");
  });
});

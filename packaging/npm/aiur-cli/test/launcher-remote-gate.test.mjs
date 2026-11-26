import { test, expect } from "bun:test";
import { useTempRoot } from "./launcher-support.mjs";
import { registry, runRemote, setupRemoteLauncher, startServer, successBody } from "./launcher-remote-support.mjs";

useTempRoot();

function run(args) {
  const server = startServer({ body: successBody() });
  try {
    const result = runRemote(setupRemoteLauncher(registry(server.url)), ["--instance", "t", ...args]);
    return { result, requests: server.requests() };
  } finally {
    server.stop();
  }
}

test("redispatch reaches the remote server with the local expression", () => {
  const { result, requests } = run(["redispatch", "12"]);
  expect(result.status).toBe(0);
  expect(requests).toHaveLength(1);
  expect(requests[0].body.expression).toBe('Aiur.AgentControlCLI.redispatch(["12"], nil)');
});

test("ticket estimate and operator-relay-answer and history label-writes make one request", () => {
  for (const args of [
    ["ticket", "estimate", "12"],
    ["operator-relay-answer", "dec_1", "--expected-version", "1", "--option", "keep", "--quote", "q", "--relayed-by", "ex", "--idempotency-key", "k"],
    ["history", "label-writes", "status"],
  ]) {
    const { requests } = run(args);
    expect(requests).toHaveLength(1);
  }
});

test("history export stays local and makes no request", () => {
  const { result, requests } = run(["history", "export"]);
  expect(result.status).toBe(64);
  expect(requests).toHaveLength(0);
});

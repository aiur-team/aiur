import { test, expect } from "bun:test";
import { useTempRoot } from "./launcher-support.mjs";
import { registry, runRemote, setupRemoteLauncher, startServer, successBody } from "./launcher-remote-support.mjs";

useTempRoot();

function run(args) {
  const server = startServer({ body: successBody() });
  try {
    const result = runRemote(setupRemoteLauncher(registry(server.url)), ["--instance", "t", ...args]);
    return { result, requests: server.requests(), stderr: String(result.stderr ?? "") };
  } finally {
    server.stop();
  }
}

test("ticket owner makes one remote request with the owner expression", () => {
  const { requests } = run(["ticket", "owner", "12", "--json"]);
  expect(requests).toHaveLength(1);
  expect(requests[0].body.expression).toBe('Aiur.AgentControlCLI.ticket_owner([ticket: "12", json: true])');
});

test("a remote ticket assign never carries force and is attributed to a non-human actor", () => {
  const { requests } = run(["ticket", "assign", "12", "--to", "nook", "--reason", "x"]);
  expect(requests).toHaveLength(1);
  const expression = requests[0].body.expression;
  expect(expression).toContain("Aiur.AgentControlCLI.ticket_assign([");
  expect(expression).toContain('as: "remote"');
  expect(expression).not.toContain("force");
});

test("--force over --instance is refused locally and sends nothing", () => {
  const { result, requests, stderr } = run(["ticket", "assign", "12", "--to", "nook", "--reason", "x", "--force"]);
  expect(result.status).toBe(64);
  expect(stderr).toContain("--force is local and human only");
  expect(requests).toHaveLength(0);
});

test("--force with --as is refused and sends nothing", () => {
  const { result, requests, stderr } = run(["ticket", "assign", "12", "--to", "nook", "--reason", "x", "--force", "--as", "e1"]);
  expect(result.status).toBe(64);
  expect(stderr).toContain("--force is local and human only");
  expect(requests).toHaveLength(0);
});

test("ticket assign refuses missing --to and an empty reason", () => {
  for (const args of [["ticket", "assign", "12", "--reason", "x"], ["ticket", "assign", "12", "--to", "nook", "--reason", " "], ["ticket", "assign", "abc", "--to", "nook", "--reason", "x"]]) {
    const { result, requests } = run(args);
    expect(result.status).toBe(64);
    expect(requests).toHaveLength(0);
  }
});

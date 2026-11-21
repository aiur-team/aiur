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

for (const action of ["confirm", "dismiss"]) {
  test(`blocker ${action} sends the Executor verdict for one declared link`, () => {
    const { requests } = run(["blocker", action, "741", "739"]);
    expect(requests).toHaveLength(1);
    expect(requests[0].body.expression).toBe(`Aiur.AgentControlCLI.blocker([action: :${action}, ticket: "741", blocker: "739"])`);
  });
}

test("blocker refuses an unknown verdict or non-numeric ids and sends nothing", () => {
  for (const args of [["blocker", "hold", "741", "739"], ["blocker", "confirm", "741"], ["blocker", "confirm", "#741", "739"], ["blocker", "dismiss", "741", "0"]]) {
    const { result, requests } = run(args);
    expect(result.status).toBe(64);
    expect(requests).toHaveLength(0);
  }
});

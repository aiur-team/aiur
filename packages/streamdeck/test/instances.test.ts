import { mkdtempSync, mkdirSync, writeFileSync, chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { loadInstances, parseInstances, resolveInstance, validateInstanceUrl, type InstanceTarget } from "../src/instances.js";

const dirs: string[] = [];
const temp = () => { const dir = mkdtempSync(path.join(tmpdir(), "sd207-registry-")); dirs.push(dir); return dir; };
afterEach(() => dirs.splice(0).forEach((dir) => rmSync(dir, { recursive: true, force: true })));
const local: InstanceTarget = { name: "local", baseUrl: "http://127.0.0.1:4000", auth: { username: "op", password: "private" } };
const registry = (field = "token_env: AIUR_TOKEN_REMOTE", url = "https://remote.test") => `version: 1\ninstances:\n  remote:\n    url: ${url}\n    ${field}\n`;

describe("instance registry", () => {
  it("loads local first, preserves order and accepts the CLI's quoted scalars/comments", () => {
    const home = temp(); mkdirSync(path.join(home, ".aiur"));
    writeFileSync(path.join(home, ".aiur/remote-instances.yaml"), registry('token_file: "~/tokens/remote"', "'https://remote.test'") + "  secondary: # desktop\r\n    url: http://localhost:4000 # loopback\n    token_env: AIUR_TOKEN_SECONDARY\n");
    expect(loadInstances(local, home)).toEqual({ targets: [local,
      { name: "remote", baseUrl: "https://remote.test", auth: { token_file: "~/tokens/remote" } },
      { name: "secondary", baseUrl: "http://localhost:4000", auth: { token_env: "AIUR_TOKEN_SECONDARY" } },
    ] });
    expect(parseInstances("# comment\n\nversion: 1\ninstances:\n")).toEqual([]);
    expect(parseInstances("instances:\nversion: 1\n")).toEqual([]);
  });
  it("keeps local when registry is missing, corrupt or unreadable", () => {
    const home = temp(); expect(loadInstances(local, home)).toEqual({ targets: [local] });
    mkdirSync(path.join(home, ".aiur"));
    const file = path.join(home, ".aiur/remote-instances.yaml");
    writeFileSync(file, "broken");
    expect(loadInstances(local, home)).toEqual({ targets: [local], error: "Invalid or unreadable remote-instances.yaml" });
    rmSync(file); mkdirSync(file);
    expect(loadInstances(local, home).error).toBe("Invalid or unreadable remote-instances.yaml");
  });
  it.each([
    "version: 2\ninstances:", "version: 1\nversion: 1\ninstances:", "version: 1\ninstances:\ninstances:",
    "instances:", "version: 1", "version: 1\n  remote:\n", "version: 1\ninstances:\n  remote:\n    token_env: AIUR_TOKEN_X",
    registry() + "    url: https://other.test", registry() + "    token_file: /tmp/token", registry("unknown: value"),
    registry().replace("remote:", "all:"), registry().replace("remote:", "local:"), registry().replace("remote:", ".:"), registry().replace("remote:", "..:"),
    registry() + "  remote:\n", registry().replace("  remote", " remote"), registry().replace("    url", "\turl"),
    "version: 1\ninstances:\n    url: https://remote.test", registry("token_env: null"), registry("token_env: ~"),
    registry('token_env: "unterminated'), registry('token_env: "bad\\escape"'), registry('token_env: "bad"quote"'),
    registry("token_env: ''"), registry("token_env: [array]"), registry("token_env: &alias"),
  ])("refuses malformed or ambiguous registry without echoing its content: %s", (text) => {
    expect(() => parseInstances(text)).toThrow("Invalid remote-instances.yaml registry");
  });
  it.each(["http://localhost:4000", "http://127.4.5.6:4000", "http://[::1]:4000", "https://remote.test"]) ("accepts %s", (url) => expect(validateInstanceUrl(url)).toBe(new URL(url).origin));
  it.each(["garbage", "http://remote.test", "http://128.0.0.1", "ftp://localhost", "https://user:secret@remote.test", "https://remote.test/path", "https://remote.test?token=secret", "https://remote.test#fragment"]) ("refuses %s", (url) => expect(() => validateInstanceUrl(url)).toThrow("HTTPS or loopback HTTP"));
  it("resolves token references only at connection time, rechecking mode and content", () => {
    const home = temp(); const file = path.join(home, "token");
    const remote: InstanceTarget = { name: "remote", baseUrl: "https://remote.test/", auth: { token_file: "~/token" } };
    writeFileSync(file, "private-token\n", { mode: 0o600 });
    expect(resolveInstance(remote, home).auth).toEqual({ token: "private-token" });
    expect(resolveInstance({ ...remote, auth: { token_file: file } }, home).baseUrl).toBe("https://remote.test");
    chmodSync(file, 0o644); expect(() => resolveInstance(remote, home)).toThrow("mode 0600");
    chmodSync(file, 0o600); writeFileSync(file, "bad token"); expect(() => resolveInstance(remote, home)).toThrow("not bearer-safe");
    expect(() => resolveInstance({ ...remote, auth: { token_file: home } }, home)).toThrow("mode 0600");
    expect(() => resolveInstance({ ...remote, auth: { token_file: "/missing/sd207" } }, home)).toThrow("mode 0600");
    expect(() => resolveInstance({ ...remote, auth: { token_file: "relative" } }, home)).toThrow("absolute");
    expect(resolveInstance(local, home).auth).toEqual(local.auth);
    expect(resolveInstance({ ...remote, auth: { token_env: "AIUR_TOKEN_REMOTE" } }, home, { AIUR_TOKEN_REMOTE: "env-token" }).auth).toEqual({ token: "env-token" });
    expect(() => resolveInstance({ ...remote, auth: { token_env: "OTHER" } }, home, {})).toThrow("AIUR_TOKEN_*");
    expect(() => resolveInstance({ ...remote, auth: { token_env: "AIUR_TOKEN_MISSING" } }, home, {})).toThrow("not bearer-safe");
  });
});

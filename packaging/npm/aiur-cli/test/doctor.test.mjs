import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync, rmSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const doctor = fileURLToPath(new URL("../libexec/aiur-mise-doctor", import.meta.url));

function runDoctor(tcp4, tcp6, lsofOutput = null) {
  const root = mkdtempSync(path.join(tmpdir(), "aiur-doctor-"));
  const procNet = path.join(root, "proc-net");
  const engineDir = path.join(root, "engine");
  const shims = path.join(root, "shims");
  mkdirSync(procNet);
  mkdirSync(path.join(engineDir, "engine"), { recursive: true });
  mkdirSync(shims);
  if (tcp4 !== null) writeFileSync(path.join(procNet, "tcp"), tcp4);
  if (tcp6 !== null) writeFileSync(path.join(procNet, "tcp6"), tcp6);
  writeFileSync(path.join(engineDir, "engine", "identity.sh"), "export ERL_AFLAGS='-kernel inet_dist_use_interface {127,0,0,1}'\n");
  const copiedDoctor = path.join(root, "aiur-mise-doctor");
  copyFileSync(doctor, copiedDoctor);
  chmodSync(copiedDoctor, 0o755);
  const lsofBin = path.join(root, "lsof");
  if (lsofOutput !== null) {
    writeFileSync(lsofBin, `#!/usr/bin/env bash\ncat <<'AIUR_LSOF_OUTPUT'\n${lsofOutput}\nAIUR_LSOF_OUTPUT\n`);
    chmodSync(lsofBin, 0o755);
  }

  try {
    return spawnSync("bash", [copiedDoctor], {
      encoding: "utf8",
      env: {
        ...process.env,
        MISE_SHIMS_DIR: shims,
        ERL_EPMD_PORT: "4369",
        AIUR_TEST_PROC_NET_DIR: procNet,
        AIUR_TEST_ENGINE_DIR: engineDir,
        ...(lsofOutput === null ? {} : { AIUR_TEST_LSOF_BIN: lsofBin }),
      },
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

const procHeader = "sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n";

test("doctor reports measured loopback and wildcard EPMD listeners plus engine bind config", () => {
  const tcp4 = `${procHeader}0: 0100007F:1111 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 1\n1: 00000000:1111 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 2\n`;
  const result = runDoctor(tcp4, procHeader);

  expect(result.status).toBe(0);
  expect(result.stdout).toContain("distribution: epmd listeners not loopback (127.0.0.1:4369,0.0.0.0:4369)");
  expect(result.stdout).toContain("inet_dist_use_interface=127.0.0.1 (engine config)");
});

test("doctor says the EPMD listener was not found instead of claiming it is safe", () => {
  const result = runDoctor(procHeader, procHeader);

  expect(result.status).toBe(0);
  expect(result.stdout).toContain("distribution: epmd listener not found on port 4369");
  expect(result.stdout).toContain("inet_dist_use_interface=127.0.0.1 (engine config)");
});

test("doctor recognizes IPv6 loopback and rejects an IPv6 wildcard listener", () => {
  const tcp6 = `${procHeader}0: 00000000000000000000000001000000:1111 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 1\n`;
  const loopback = runDoctor(procHeader, tcp6);

  expect(loopback.status).toBe(0);
  expect(loopback.stdout).toContain("distribution: epmd listeners [0000:0000:0000:0000:0000:0000:0000:0001]:4369");
  expect(loopback.stdout).not.toContain("not loopback");

  const wildcardTcp6 = `${procHeader}0: 00000000000000000000000000000000:1111 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 2\n`;
  const wildcard = runDoctor(procHeader, wildcardTcp6);

  expect(wildcard.status).toBe(0);
  expect(wildcard.stdout).toContain("distribution: epmd listeners not loopback");
});

test("doctor falls back to lsof output when procfs is unavailable", () => {
  const warning = "lsof: WARNING: cannot read process details";
  const listener = "epmd 123 root 3u IPv6 123 0t0 TCP [::1]:4369 (LISTEN)";
  const result = runDoctor(null, null, `${warning}\n${listener}`);

  expect(result.status).toBe(0);
  expect(result.stdout).toContain("distribution: epmd listeners [::1]:4369");
  expect(result.stdout).toContain("inet_dist_use_interface=127.0.0.1 (engine config)");
});

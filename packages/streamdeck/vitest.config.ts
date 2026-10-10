import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    coverage: {
      provider: "v8",
      reporter: ["text"],
      include: ["src/**/*.{ts,tsx,mts,cts}"],
      // main.ts is the process entry point: it only wires real Node primitives
      // (net, child_process, fs, process) into the fully-tested startRuntime.
      // Its device discovery and env parsing live in the tested device-path.ts,
      // so what remains is branch-free wiring, excluded here rather than covered
      // through brittle module mocks of Node built-ins.
      // These are process/network wiring and native rasterization boundaries;
      // their behavior is exercised through focused integration tests, while
      // the 100% unit threshold remains for the pure protocol/render modules.
      // The siblings split out of those files for size keep their exclusion:
      // hid-device.ts and sidecar-wiring.ts hold main.ts's wiring, key-face.ts
      // the rasterizer's painters. No code that was measured left the gate.
      exclude: [
        "src/main.ts",
        "src/hid-device.ts",
        "src/sidecar-wiring.ts",
        "src/channel.ts",
        "src/controller.ts",
        "src/rasterizer.ts",
        "src/key-face.ts",
        "src/surface.ts",
      ],
      thresholds: {
        branches: 100,
        functions: 100,
        lines: 100,
        statements: 100,
      },
    },
  },
});

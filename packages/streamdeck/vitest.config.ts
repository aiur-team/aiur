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
      exclude: ["src/main.ts"],
      thresholds: {
        branches: 100,
        functions: 100,
        lines: 100,
        statements: 100,
      },
    },
  },
});

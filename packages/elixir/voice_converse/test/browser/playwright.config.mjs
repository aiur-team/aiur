import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: "*.spec.mjs",
  fullyParallel: true,
  reporter: "list",
  use: { baseURL: "http://127.0.0.1:4187", browserName: "chromium", viewport: { width: 1280, height: 900 } },
  webServer: {
    command: "MIX_ENV=test mise exec -- mix run --no-start browser_test/host.exs",
    cwd: "../..",
    url: "http://127.0.0.1:4187/talk.html",
    reuseExistingServer: !process.env.CI,
  },
});

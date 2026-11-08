import { defineConfig, devices } from '@playwright/test';

// The package's browser spec runs the fixture page against its own source, so
// the Chromium check covers what a consumer actually loads.
export default defineConfig({
  testDir: 'test/browser',
  fullyParallel: false,
  forbidOnly: Boolean(process.env.CI),
  retries: 0,
  workers: 1,
  reporter: process.env.CI ? [['github'], ['list']] : 'list',
  use: {
    baseURL: 'http://127.0.0.1:4173',
    trace: 'retain-on-failure',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: {
    command: 'node scripts/serve-fixtures.mjs',
    url: 'http://127.0.0.1:4173/tokens.css',
    reuseExistingServer: !process.env.CI,
    timeout: 30_000,
  },
});

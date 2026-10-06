import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './test',
  testMatch: '**/*.visual.spec.ts',
  webServer: {
    command: 'http-server . -p 3000 -c-1',
    port: 3000,
    reuseExistingServer: false,
  },
  use: {
    baseURL: 'http://localhost:3000/gallery/',
    trace: 'retain-on-failure',
    reducedMotion: 'reduce',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  retries: 0,
  timeout: 30000,
});

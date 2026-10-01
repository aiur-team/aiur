import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './test',
  testMatch: '**/*.visual.spec.ts',
  webServer: {
    command: 'npx http-server ./gallery -p 3000 -c-1',
    port: 3000,
    reuseExistingServer: false,
  },
  use: {
    baseURL: 'http://localhost:3000',
    trace: 'on-first-retry',
  },
  projects: [
    {
      name: 'Light Theme',
      use: {
        ...devices['Desktop Chrome'],
        colorScheme: 'light',
      },
    },
    {
      name: 'Dark Theme',
      use: {
        ...devices['Desktop Chrome'],
        colorScheme: 'dark',
      },
    },
  ],
  retries: 2,
  timeout: 30000,
});

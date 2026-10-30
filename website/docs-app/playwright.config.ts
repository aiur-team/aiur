import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './tests',
  testMatch: 'lifecycle-responsive.spec.ts',
  outputDir: './test-results',
  workers: 1,
  use: { baseURL: 'http://127.0.0.1:43128/docs/' },
  webServer: {
    command: 'npm run preview -- --host 127.0.0.1 --port 43128',
    url: 'http://127.0.0.1:43128/docs/concepts/lifecycle',
    reuseExistingServer: false
  }
})

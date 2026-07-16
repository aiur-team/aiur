import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './tests',
  use: {
    baseURL: 'http://127.0.0.1:43127',
    launchOptions: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH
      ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH }
      : {}
  },
  webServer: {
    command: 'npm run preview -- --host 127.0.0.1 --port 43127',
    url: 'http://127.0.0.1:43127',
    reuseExistingServer: false
  }
})

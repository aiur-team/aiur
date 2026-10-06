import { defineConfig, devices } from '@playwright/test'

export default defineConfig({
  testDir: './tests',
  updateSnapshots: 'none',
  workers: 4,
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
  },
  projects: [
    {
      name: 'brand',
      testMatch: ['**/brand.spec.ts', '**/gui-docs.spec.ts'],
      use: {
        ...devices['Desktop Chrome']
      }
    },
    {
      name: 'visual',
      testMatch: ['**/visual.spec.ts', '**/visual.selftest.spec.ts'],
      use: {
        ...devices['Desktop Chrome'],
        reducedMotion: 'reduce'
      },
      snapshotPathTemplate: 'tests/visual.spec.ts-snapshots/{platform}/{testFileName}-{arg}{ext}',
      expect: {
        toHaveScreenshot: {
          maxDiffPixelRatio: 0.002,
          threshold: 0.2,
          animations: 'disabled',
          caret: 'hide',
          scale: 'device'
        }
      }
    }
  ]
})

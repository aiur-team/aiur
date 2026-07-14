import { defineConfig } from '@playwright/test'

const port = Number.parseInt(process.env.AIUR_BROWSER_PORT ?? '', 10)

if (!Number.isInteger(port) || port < 1 || port > 65_535) {
  throw new Error('AIUR_BROWSER_PORT must be an allocated loopback port; use npm run test:smoke or npm run test:harness')
}

const artifactRoot = process.env.AIUR_BROWSER_ARTIFACT_DIR ?? '.artifacts/unmanaged'

export default defineConfig({
  testDir: './tests',
  outputDir: artifactRoot,
  fullyParallel: false,
  forbidOnly: Boolean(process.env.CI),
  retries: 0,
  workers: 1,
  timeout: 30_000,
  expect: { timeout: 10_000 },
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure'
  },
  webServer: {
    command: 'npm run fixture:server',
    cwd: '.',
    url: `http://127.0.0.1:${port}/health`,
    reuseExistingServer: false,
    timeout: 30_000,
    stdout: 'pipe',
    stderr: 'pipe'
  }
})

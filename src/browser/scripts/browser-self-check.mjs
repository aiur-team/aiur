import process from 'node:process'
import { runBrowserTests } from './run-browser-tests.mjs'

try {
  const result = await runBrowserTests(['tests/liveview-smoke.spec.mjs'])
  if (result.code !== 0) throw new Error(`npx playwright exited code=${result.code} signal=${result.signal ?? 'none'}`)
  process.stdout.write('Browser self-check passed: fixture server and project-pinned Playwright Chromium smoke completed.\n')
} catch (error) {
  process.stderr.write(`Browser self-check failed: ${error?.stack ?? error}\n`)
  process.exitCode = 1
}

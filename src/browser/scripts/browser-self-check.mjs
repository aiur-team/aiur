import process from 'node:process'
import { runBrowserTests } from './run-browser-tests.mjs'

export async function browserSelfCheck(runTests = runBrowserTests, output = process) {
  try {
    const result = await runTests(['tests/liveview-smoke.spec.mjs'])
    if (result.code !== 0) {
      const diagnostic = result.stderr ? `\n${result.stderr}` : ''
      throw new Error(`npx playwright exited code=${result.code} signal=${result.signal ?? 'none'}${diagnostic}`)
    }
    output.stdout.write('Browser self-check passed: fixture server and project-pinned Playwright Chromium smoke completed.\n')
    return 0
  } catch (error) {
    output.stderr.write(`Browser self-check failed: ${error?.stack ?? error}\n`)
    return 1
  }
}

if (process.argv[1] && new URL(import.meta.url).pathname === process.argv[1]) {
  process.exitCode = await browserSelfCheck()
}

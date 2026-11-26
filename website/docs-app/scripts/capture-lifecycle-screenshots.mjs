import { spawn } from 'node:child_process'
import { mkdir } from 'node:fs/promises'
import { resolve } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { chromium } from '@playwright/test'

const port = 43972
const baseURL = `http://127.0.0.1:${port}/docs/concepts/lifecycle`
const preview = spawn('bun', ['run', 'preview', '--', '--host', '127.0.0.1', `--port=${port}`], { stdio: 'ignore' })
const output = resolve(process.cwd(), '../../.github/screenshots/issue-4597')
const captures = [
  { name: 'desktop', width: 1440, height: 900 },
  { name: 'mobile', width: 390, height: 844 }
]
let browser

try {
  await mkdir(output, { recursive: true })
  let ready = false
  for (let attempt = 0; attempt < 60; attempt++) {
    try {
      const response = await fetch(baseURL)
      if (response.ok) { ready = true; break }
    } catch {}
    await delay(250)
  }
  if (!ready) throw new Error('VitePress preview did not become ready')
  browser = await chromium.launch({ headless: true })
  const page = await browser.newPage()
  await page.emulateMedia({ reducedMotion: 'reduce' })
  for (const capture of captures) {
    await page.setViewportSize({ width: capture.width, height: capture.height })
    await page.goto(baseURL, { waitUntil: 'networkidle' })
    await page.addStyleTag({ content: '*,*::before,*::after{transition:none!important;animation:none!important}' })
    for (const theme of ['light', 'dark']) {
      await page.evaluate((dark) => document.documentElement.classList.toggle('dark', dark), theme === 'dark')
      await page.waitForTimeout(100)
      await page.screenshot({
        path: resolve(output, `${capture.name}-${theme}.jpg`),
        type: 'jpeg',
        quality: 72,
        fullPage: false
      })
    }
  }
} finally {
  await browser?.close()
  preview.kill('SIGTERM')
}

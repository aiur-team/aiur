import { expect, test } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { renderCommand } from '../../../packages/aiur-commands/src/render.mjs'

const rendererSource = readFileSync(fileURLToPath(new URL('../../../packages/aiur-commands/src/render.mjs', import.meta.url)), 'utf8')
const buildUrl = 'https://play.example.test/builds/42?level=3'

const command = {
  state: 'pending',
  decision_id: 'dec_embed',
  question: 'Does level 3 feel right?',
  options: [
    {
      id: 'ship',
      label: 'Ship it',
      media: [{ kind: 'embed', mime_type: 'text/html', alt_text: 'Level 3 playable build', locator: { kind: 'url', value: buildUrl } }]
    },
    { id: 'hold', label: 'Hold' }
  ],
  media: [],
  actions: { answer: true }
}

async function open(page) {
  const requests = []
  await page.route('https://play.example.test/**', (route) => {
    requests.push(route.request().url())
    return route.fulfill({ contentType: 'text/html', body: '<!doctype html><title>build</title><p id="game">Level 3 running</p>' })
  })
  await page.setContent(`<!doctype html><main>${renderCommand(command)}</main>`)
  await page.addScriptTag({ type: 'module', content: `${rendererSource}\nbindEmbeds(document); window.embedsBound = true;` })
  await expect.poll(() => page.evaluate(() => window.embedsBound === true)).toBe(true)
  return requests
}

test('an embed loads its sandboxed iframe only after the operator clicks Load', async ({ page }) => {
  const requests = await open(page)
  await expect(page.locator('iframe')).toHaveCount(0)
  expect(requests).toEqual([])

  await page.getByRole('button', { name: 'Load Level 3 playable build' }).click()

  const iframe = page.locator('iframe')
  await expect(iframe).toHaveCount(1)
  await expect(iframe).toHaveAttribute('sandbox', 'allow-scripts')
  await expect(iframe).toHaveAttribute('referrerpolicy', 'no-referrer')
  await expect(iframe).toHaveAttribute('src', buildUrl)
  await expect(page.frameLocator('iframe').locator('#game')).toHaveText('Level 3 running')
  expect(requests).toEqual([buildUrl])
  await expect(page.getByRole('button', { name: 'Load Level 3 playable build' })).toHaveCount(0)
})

test('an option-bound embed renders under its option, outside the option label', async ({ page }) => {
  await open(page)
  const optionMedia = page.locator('[data-option-media="ship"]')

  await expect(optionMedia.getByRole('button', { name: 'Load Level 3 playable build' })).toBeVisible()
  await expect(optionMedia.getByRole('link', { name: 'Open in a new tab' })).toHaveAttribute('href', buildUrl)
  await expect(page.locator('[data-option-id="ship"] [data-part="embed"]')).toHaveCount(0)
  await expect(page.locator('[data-option-media="hold"]')).toHaveCount(0)

  await optionMedia.getByRole('button', { name: 'Load Level 3 playable build' }).click()
  await expect(optionMedia.locator('iframe')).toHaveCount(1)
  await expect(page.getByLabel('Ship it')).not.toBeChecked()
})

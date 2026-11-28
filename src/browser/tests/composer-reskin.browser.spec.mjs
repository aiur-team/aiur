import { fileURLToPath } from 'node:url'
import { expect, test } from '@playwright/test'

const packageRoot = new URL('../../../packages/aiur-conversation/', import.meta.url)

test('a host theme and slotted send preserve the default composer behavior', async ({ page }) => {
  await page.route(/\/composer-example\/(examples\/composer\.html|src\/[a-z-]+\.mjs)(\?|$)/, (route) => {
    const path = new URL(route.request().url()).pathname.replace('/composer-example/', '')
    return route.fulfill({ path: fileURLToPath(new URL(path, packageRoot)) })
  })

  const payloads = []
  for (const skin of ['', '?skin=ogm']) {
    await page.goto(`/composer-example/examples/composer.html${skin}`)
    const composer = page.locator('aiur-composer')
    const send = composer.getByRole('button', { name: 'Send', exact: true })
    const input = composer.getByRole('textbox', { name: 'Message' })
    await expect(send).toBeDisabled()
    if (skin) {
      await expect(composer.locator('[part="card"]')).toHaveCSS('background-color', 'rgb(255, 250, 240)')
      await expect(input).toHaveCSS('border-bottom-color', 'rgb(89, 103, 67)')
      await expect(send).toHaveAttribute('slot', 'send')
      await expect(composer.locator('[part="send"]')).toBeHidden()
    }

    await composer.evaluate((element) => {
      element.addEventListener('aiur-send', ({ detail }) => {
        element.dataset.sent = JSON.stringify(detail)
      }, { once: true })
    })
    await input.fill('  Ship the draft  ')
    await expect(send).toBeEnabled()
    await send.click()
    await expect(page.locator('#log li')).toHaveText('Ship the draft')
    await expect(input).toHaveValue('')
    await expect(send).toBeDisabled()
    payloads.push(JSON.parse(await composer.getAttribute('data-sent')))
  }
  expect(payloads).toEqual(Array(2).fill({ text: 'Ship the draft', attachments: [] }))
})

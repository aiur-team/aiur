import { test } from '@playwright/test'
import { readFile } from 'node:fs/promises'

export async function pairedBrowser(browser) {
  const root = test.info().project.metadata.featuresRoot
  if (!root) return browser
  return { newContext: async options => {
    const context = await browser.newContext(options), newPage = context.newPage.bind(context)
    context.newPage = async () => {
      const page = await newPage()
      await page.route('**/build-home/*.js', async route => route.fulfill({ contentType: 'text/javascript', body: await readFile(root + '/src/priv/static/build-home/' + new URL(route.request().url()).pathname.split('/').at(-1), 'utf8') }))
      return page
    }
    return context
  } }
}

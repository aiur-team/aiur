import { readFile } from 'node:fs/promises'
import { test } from '@playwright/test'
import { openParityPair } from './design-parity.mjs'

// Serve only the isolated worktree's modal during mutation checks; fixture data and transport stay real.
export async function openModalPair(browser, cell, options) {
  const root = test.info().project.metadata.agentAssets
  if (!root) return openParityPair(browser, cell, options)
  return openParityPair({ newContext: async opts => {
    const context = await browser.newContext(opts)
    return { close: () => context.close(), newPage: async () => {
      const page = await context.newPage()
      for (const name of ['modal/frame.js', 'modal/header.js', 'modal/focus.js', 'modal/agent-control.js', 'modal/doc.js', 'modal/conversation.js', 'modal/conversation-items.js', 'modal/conversation-events.js', 'modal/conversation-footer.js', 'hook.js', 'home.css', 'home/19-modal-doc.css']) await page.route('**/build-home/' + name, async route => route.fulfill({
        body: await readFile(root + '/' + name, 'utf8'), contentType: name.endsWith('.css') ? 'text/css' : 'text/javascript',
      }))
      return page
    } }
  } }, cell, options)
}

// Interface note 1: the server sends chat: null, so the product hides "Open in Conversations"
// until C14-T03 gives it a destination. Scope the design's button out of header parity until then.
export const hideDesignChat = pair => pair.design.addStyleTag({ content: '.bm-agent [data-a="chat"] { display: none !important; }' })

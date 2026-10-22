import { expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { openParityPair, loadAllowlist, applyAllowlist } from './design-parity.mjs'

async function normalizeNavigation(pair, dataset) {
  const fixture = JSON.parse(await readFile(new URL(`../../test/fixtures/build_home/${dataset}.json`, import.meta.url), 'utf8'))
  const agentSource = fixture.sources?.agents?.state
  const active = ['ok', 'stale'].includes(agentSource)
    ? new Set(fixture.sections.now.filter(row => row.sec === 'now' && row.agent?.state === 'active').map(row => row.id)).size
    : null
  const badge = pair.product.locator('a.snav[href="/"] .snav-c')
  if (active === null) await expect(badge).toHaveCount(0)
  else await expect(badge).toHaveText(String(active))
  await pair.design.locator('#tabcount-fleet').evaluate((node, count) => {
    node.textContent = count === null ? '' : String(count)
    node.hidden = count === null
    node.style.display = count === null ? 'none' : ''
  }, active)
  // This fixture has no retained Commands count source. The unrelated design
  // inbox seed must not invent a waiting Command in the reference shell.
  await expect(pair.product.locator('a.snav[href="/commands"] .snav-c')).toHaveCount(0)
  await pair.design.locator('#tabcount-inbox').evaluate(node => {
    node.textContent = ''
    node.hidden = true
    node.style.display = 'none'
  })
}

export async function openCutoverParityPair(browser, cell) {
  const pair = await openParityPair(browser, cell, { motion: true })
  try {
    // Compare the supported base shell; the normal enabled capability is
    // exercised separately by the product cutover navigation test.
    expect(process.env.AIUR_BROWSER_FIXTURE_MODE).toBe('base-navigation')
    await expect(pair.product.locator('.sidenav-nav a.snav')).toHaveCount(4)
    await expect(pair.product.getByRole('link', { name: 'Experiments', exact: true })).toHaveCount(0)
    const baseNavigation = await loadAllowlist(new URL('./design-parity-base-navigation.json', import.meta.url))
    pair.allowlist = pair.allowlist.filter(entry => entry.id !== 'experiments-nav').concat(baseNavigation)
    await normalizeNavigation(pair, cell.dataset)
    await applyAllowlist(pair, cell)
    return pair
  } catch (error) {
    await pair.close()
    throw error
  }
}

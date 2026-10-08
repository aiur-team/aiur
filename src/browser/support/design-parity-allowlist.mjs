import { test } from '@playwright/test'
import { readFile } from 'node:fs/promises'

const nonempty = value => typeof value === 'string' && value.trim().length > 0
const kinds = ['design-removal', 'pixel-mask', 'design-style', 'property', 'motion', 'axe', 'copy']
const removals = new WeakMap()
export async function loadAllowlist(source = new URL('./design-parity-allowlist.json', import.meta.url)) {
  const entries = JSON.parse(await readFile(source, 'utf8'))
  if (!Array.isArray(entries)) throw new Error('allowlist must be an array')
  const ids = new Set()
  for (const entry of entries) {
    const a = entry.approval
    const valid = nonempty(entry.id) && !ids.has(entry.id) && kinds.includes(entry.kind) && nonempty(entry.selector) && nonempty(entry.reason)
      && !Object.hasOwn(entry, 'approved') && a && nonempty(a.ref)
      && (a.status === 'pending-sign-off' || (a.status === 'approved' && a.by === 'Kevin' && /^\d{4}-\d{2}-\d{2}$/.test(a.date) && !Number.isNaN(Date.parse(a.date)) && new Date(a.date).toISOString().slice(0, 10) === a.date))
      && Object.entries({ css: 'design-style', property: 'property', rule: 'axe', path: 'motion' }).every(([field, kind]) => entry.kind === kind ? nonempty(entry[field]) : entry[field] == null)
      && (entry.kind !== 'motion' || !entry.path.includes('*') || entry.path === '*')
      && Object.entries(entry.cells ?? {}).every(([key, value]) => ['viewport', 'theme', 'palette', 'dataset'].includes(key) && nonempty(value))
    if (!valid) throw new Error(`invalid allowlist entry ${entry.id ?? '(unnamed)'}`)
    ids.add(entry.id)
  }
  reportPending(entries)
  return entries
}

export function reportPending(entries) {
  for (const entry of entries.filter(e => e.approval.status === 'pending-sign-off')) {
    const description = `${entry.id}: pending-sign-off (${entry.approval.ref})`
    console.log(description)
    const annotations = test.info().annotations
    if (!annotations.some(a => a.type === 'pending-sign-off' && a.description === description)) annotations.push({ type: 'pending-sign-off', description })
  }
}

export async function applyAllowlist(pair, cell, entries) {
  entries ??= pair.allowlist ?? await loadAllowlist()
  const masks = { designMask: [], productMask: [] }
  for (const entry of entries) {
    if (!Object.entries(entry.cells ?? {}).every(([key, value]) => (key === 'viewport' ? `${cell.viewport.width}x${cell.viewport.height}` : cell[key]) === value)) continue
    // All seven kinds participate in stale-selector validation.
    const pages = entry.kind === 'pixel-mask' ? [pair.design, pair.product] : [pair.design]
    if (entry.kind === 'design-removal' && removals.get(pair.design)?.has(entry.id)) continue
    for (const page of pages) {
      if (!await page.locator(entry.selector).count()) throw new Error(`stale allowlist entry ${entry.id}`)
    }
    if (entry.kind === 'design-removal') {
      await pair.design.locator(entry.selector).evaluateAll(nodes => nodes.forEach(n => n.remove()))
      if (!removals.has(pair.design)) removals.set(pair.design, new Set())
      removals.get(pair.design).add(entry.id)
    }
    if (entry.kind === 'design-style') await pair.design.addStyleTag({ content: entry.css })
    if (entry.kind === 'pixel-mask') {
      masks.designMask.push(pair.design.locator(entry.selector))
      masks.productMask.push(pair.product.locator(entry.selector))
    }
  }
  return masks
}

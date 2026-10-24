import { test } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { basename } from 'node:path'

const nonempty = value => typeof value === 'string' && value.trim().length > 0
const kinds = ['design-removal', 'design-style', 'motion']
const removals = new WeakMap()
export async function loadAllowlist(source = new URL('./design-parity-allowlist.json', import.meta.url)) {
  const entries = JSON.parse(await readFile(source, 'utf8'))
  if (!Array.isArray(entries)) throw new Error('allowlist must be an array')
  const ids = new Set()
  for (const entry of entries) {
    const a = entry.approval
    const valid = nonempty(entry.id) && !ids.has(entry.id) && kinds.includes(entry.kind) && nonempty(entry.selector) && nonempty(entry.reason)
      && !Object.hasOwn(entry, 'approved') && a && nonempty(a.ref)
      && (entry.spec == null || (nonempty(entry.spec) && /^[a-z0-9-]+\.browser\.spec\.mjs$/.test(entry.spec)))
      && (a.status === 'pending-sign-off' || (a.status === 'approved' && a.by === 'Kevin' && /^\d{4}-\d{2}-\d{2}$/.test(a.date) && !Number.isNaN(Date.parse(a.date)) && new Date(a.date).toISOString().slice(0, 10) === a.date))
      && Object.entries({ css: 'design-style', path: 'motion' }).every(([field, kind]) => entry.kind === kind ? nonempty(entry[field]) : entry[field] == null)
      && (entry.kind !== 'motion' || !/[?{}]/.test(entry.path))
      && (entry.productWhen == null || nonempty(entry.productWhen))
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
  for (const entry of entries) {
    if (entry.spec && entry.spec !== basename(test.info().file)) continue
    // Motion paths have their own stale-difference check.
    if (entry.kind === 'motion') continue
    // Capability-scoped differences apply only where the product exposes that capability.
    if (entry.productWhen && !await pair.product.locator(entry.productWhen).count()) continue
    if (!Object.entries(entry.cells ?? {}).every(([key, value]) => (key === 'viewport' ? `${cell.viewport.width}x${cell.viewport.height}` : cell[key]) === value)) continue
    if (entry.kind === 'design-removal' && removals.get(pair.design)?.has(entry.id)) continue
    if (!await pair.design.locator(entry.selector).count()) throw new Error(`stale allowlist entry ${entry.id}`)
    if (entry.kind === 'design-removal') {
      await pair.design.locator(entry.selector).evaluateAll(nodes => nodes.forEach(n => n.remove()))
      if (!removals.has(pair.design)) removals.set(pair.design, new Set())
      removals.get(pair.design).add(entry.id)
    }
    if (entry.kind === 'design-style') await pair.design.addStyleTag({ content: entry.css })
  }
}


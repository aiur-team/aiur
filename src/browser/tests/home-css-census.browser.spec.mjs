import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { parityContextOptions } from '../support/design-parity.mjs'
import { BASE, openHomeState } from '../support/home-css-states.mjs'
import { census } from '../support/home-css-census.mjs'

test('ordered stylesheet imports preserve source order and Safari blur fallbacks', async () => {
  const entry = new URL('../../priv/static/build-home/home.css', import.meta.url)
  const imports = [...(await readFile(entry, 'utf8')).matchAll(/@import url\("home\/([^"/]+)"\);/g)]
  expect(imports.length).toBeGreaterThan(0)
  expect(imports.map(([, name]) => Number(name.slice(0, 2)))).toEqual(imports.map((_, i) => i + 1))
  const parts = await Promise.all(imports.map(([, name]) => readFile(new URL(`home/${name}`, entry), 'utf8')))
  for (const part of parts) expect(part.trimEnd().split('\n').length).toBeLessThan(500)
  const css = parts.join('\n')
  const markers = [...css.matchAll(/\/\* ([HC]):(\d+) \*\//g)]
  expect(markers.map(([, source, line]) => (source === 'C' ? 10000 : 0) + Number(line))).toEqual(
    markers.map(([, source, line]) => (source === 'C' ? 10000 : 0) + Number(line)).sort((a, b) => a - b))
  const blurRules = [...css.replace(/\/\*[\s\S]*?\*\//g, '').matchAll(/([^{}]+)\{([^{}]*)\}/g)]
    .filter(([, , body]) => body.includes('-webkit-backdrop-filter:'))
    .map(([, selector, body]) => ({ selector: selector.trim(), declarations: body.match(/(?:-webkit-)?backdrop-filter:[^;]+;/g) }))
  expect(blurRules).toEqual([
    { selector: '.bd-tree', declarations: ['backdrop-filter: blur(10px) saturate(.7);', '-webkit-backdrop-filter: blur(10px) saturate(.7);'] },
    { selector: '.bd-now, html[data-palette="gruvbox"] .bd-now', declarations: ['backdrop-filter: blur(5px);', '-webkit-backdrop-filter: blur(5px);'] },
  ])
})

// Future re-import guard: cached syntax must never reuse matches from the previous DOM.
test('census cache rematches the DOM when graph changes to list', async ({ browser }) => {
  const context = await browser.newContext(parityContextOptions(BASE))
  try {
    const page = await context.newPage()
    await openHomeState(page, BASE)
    const graph = await census(page)
    const count = (records, selector) => records.filter(r => r.selector).flatMap(r => r.matches).filter(m => m.selector === selector).reduce((sum, m) => sum + m.count, 0)
    expect(count(graph, '.bd-card')).toBeGreaterThan(0)
    await openHomeState(page, { ...BASE, query: 'view=list' })
    const cached = await census(page)
    expect(count(cached, '.bd-card')).toBe(0)
    expect(count(cached, '.lr')).toBeGreaterThan(0)
    expect(count(graph, '.bd-card')).toBeGreaterThan(0)
    // Timers can change live element classes between reads; source syntax stays immutable.
    const syntax = records => records.filter(r => r.selector).map(({ matches, ...rule }) => rule)
    expect(syntax(cached)).toEqual(syntax(graph))
  } finally { await context.close() }
})

import { test, expect } from '@playwright/test'
import { writeFile } from 'node:fs/promises'
import { parityContextOptions } from '../support/design-parity.mjs'
import { HOME_MATRIX, openHomeState } from '../support/home-css-states.mjs'
import { census, renderHomeCss, ownsBuildLine, DEAD } from '../support/home-css-census.mjs'

const all = []
const combined = new Map()
const key = r => `${r.source}:${r.line}:${r.selector}:${JSON.stringify(r.context)}`
let trees
for (const cell of HOME_MATRIX) test(`future re-import guard: dead selectors unused in ${cell.name}`, async ({ browser }) => {
  const context = await browser.newContext(parityContextOptions(cell))
  try {
    const page = await context.newPage()
    await openHomeState(page, cell)
    const records = await census(page)
    all.push({ state: cell.name, rules: structuredClone(records.filter(r => r.selector)) })
    for (const rule of records.filter(r => r.selector)) {
      if (!combined.has(key(rule))) combined.set(key(rule), structuredClone(rule))
      else rule.matches.forEach((m, i) => { combined.get(key(rule)).matches[i].count += m.count })
    }
    trees ??= records.filter(r => r.tree)
    const dead = records.filter(r => r.selector).flatMap(r => r.matches.filter(m => DEAD.test(m.selector)))
    expect(dead.filter(m => m.count > 0), 'dead selector matched').toEqual([])
  } finally { await context.close() }
})

test.afterAll(async () => {
  if (!trees) return
  const update = rules => rules.forEach(r => r.children ? update(r.children) : r.selector ? Object.assign(r, combined.get(key(r))) : null)
  trees.forEach(r => update(r.tree))
  const records = [...combined.values(), ...trees]
  const { css, shadowed } = renderHomeCss(records)
  const dead = records.filter(r => r.selector).flatMap(r => r.matches.filter(m => DEAD.test(m.selector)).map(m => ({ source: r.source, line: r.line, ...m })))
  const zeroMatches = records.filter(r => r.source === 'C' && r.selector && ownsBuildLine(r.line)).flatMap(r => r.matches.filter(m => !m.count && !DEAD.test(m.selector) && !(r.line === 983 && m.selector.includes('.ax-menu'))).map(m => ({ source: r.source, line: r.line, context: r.context, ...m })))
  await writeFile(test.info().outputPath('home-css-census.json'), JSON.stringify({ states: all, dead, zeroMatches, shadowed, css, trees }, null, 2))
})

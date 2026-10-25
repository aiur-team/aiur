// Executor decision 6404203203: these remain known failures, not WCAG passes.
// Fixed DOM selectors and cells prevent this inventory from swallowing new nodes.
import { measureTextContrast } from './build-home-glyph-contrast.mjs'
export const contrastBaselines = [
  ...['Bugs', 'Infra', 'Docs', 'Design', 'Pagination · API — short-lived feature epic',
    'Pagination · UI — short-lived feature epic', 'Unsorted'].map(title => ({
    id: 'lane-count:' + title, kind: 'violations', selector: 'div[title="' + title + '"] > em',
    ratio: 4.43, plainRatio: 4.3804, followup: '#6291',
    cells: { dataset: 'dense', view: 'gantt', theme: 'dark' }
  })),
  ...[['live', '607'], ['dense', '1309'], ['newrepo', '603'], ['offline', '607'],
    ['unknowns', '607'], ['unknowns', '9005'], ['unknowns', 'pack:alpha']].map(([dataset, id]) => ({
    id: 'promotion:' + dataset + ':' + id, kind: 'violations',
    selector: 'div[data-id="' + id + '"] .bd-q.promo', ratio: 4.14, plainRatio: 4.1114,
    followup: '#6292', cells: { dataset, view: 'graph', theme: 'light' }
  })),
  ...['span[title="openrouter"] > .ax-mono', 'span[title="muse · Running"] > .ax-mono',
    'span[title="zz-new · Running"] > .ax-mono', 'span[title="muse"].ax-mono',
    'span[title="zz-new"].ax-mono'].map(selector => ({
    id: 'model-monogram:' + selector, kind: 'incomplete', selector,
    ratio: 3.8174, plainRatio: 3.8174, followup: '#6293', cells: { dataset: 'unknowns' }
  }))
]

export function baselineApplies(entry, cell) {
  return Object.entries(entry.cells).every(([key, value]) => cell[key] === value)
}

export function recordContrastBaselines(audit, cell, measurements, entries = contrastBaselines) {
  const known = []
  const consumed = new Set()
  for (const entry of entries.filter(entry => baselineApplies(entry, cell))) {
    const measured = measurements[entry.selector]
    if (measured && (measured.count !== 1 || !Number.isFinite(measured.ratio) || measured.ratio < entry.plainRatio)) {
      throw new Error('Plain-background contrast baseline worsened: ' + entry.id)
    }
  }
  const result = { ...audit }
  for (const kind of ['violations', 'incomplete']) {
    result[kind] = audit[kind].map(rule => ({ ...rule, nodes: rule.nodes.filter(node => {
      const entry = entries.find(entry => entry.kind === kind && rule.id === 'color-contrast' &&
        node.target.length === 1 && measurements[entry.selector]?.targets.includes(node.target[0]) && baselineApplies(entry, cell))
      if (!entry || consumed.has(entry.id)) return true
      const checks = [...node.any, ...node.all, ...node.none]
      if (!checks.length || !checks.every(check => check.id === 'color-contrast' &&
        (kind === 'violations' ? check.data?.messageKey == null :
          check.data?.messageKey === 'shortTextContent' && (check.relatedNodes ?? []).every(related =>
            related.target.length === 1 && measurements[entry.selector]?.targets.includes(related.target[0]))))) return true
      const measured = measurements[entry.selector]
      if (!measured || measured.count !== 1) throw new Error('Changed baseline element inventory: ' + entry.id)
      const ratio = kind === 'violations' ? Math.min(...checks.map(check => check.data.contrastRatio)) : measured.ratio
      if (!Number.isFinite(ratio) || ratio < entry.ratio) throw new Error('Contrast baseline worsened: ' + entry.id + ' ' + ratio)
      consumed.add(entry.id)
      known.push({ status: 'known baseline violation', ...entry, measuredRatio: ratio, plainBackground: measured, node })
      return false
    }) })).filter(rule => rule.nodes.length)
  }
  return { audit: result, known }
}

export async function measureContrastBaselines(page, audit, cell) {
  const measurements = {}
  const targets = [...audit.violations, ...audit.incomplete].flatMap(rule => rule.nodes)
    .filter(node => node.target.length === 1).map(node => node.target[0])
  for (const entry of contrastBaselines.filter(entry => baselineApplies(entry, cell))) {
    const count = await page.locator(entry.selector).count()
    if (!count) continue
    const [measurement] = await measureTextContrast(page, [entry.selector])
    const matching = await page.evaluate(({ targets, selector }) => targets.filter(target => {
      const nodes = document.querySelectorAll(target)
      return nodes.length === 1 && nodes[0].matches(selector)
    }), { targets, selector: entry.selector })
    measurements[entry.selector] = { ...measurement, count, targets: matching }
  }
  return measurements
}

import { expect, test } from '@playwright/test'
import { writeFile } from 'node:fs/promises'
import { parityContextOptions, loadAllowlist, applyAllowlist, FIXTURE_META, guardNetwork } from './design-parity.mjs'
import { dashboardCredentials } from '../tests/support/layout-worker.mjs'
import { ROOTS, census, ownsBuildLine } from './home-css-census.mjs'
import { openHomeState } from './home-css-states.mjs'

export async function transplant(browser, cell) {
  const designContext = await browser.newContext(parityContextOptions(cell))
  const productContext = await browser.newContext({ ...parityContextOptions(cell), baseURL: test.info().project.use.baseURL, httpCredentials: dashboardCredentials })
  const pair = { design: await designContext.newPage(), product: await productContext.newPage(), cell,
    close: async () => { await designContext.close(); await productContext.close() } }
  try {
    await openHomeState(pair.design, cell)
    pair.allowlist = (await loadAllowlist()).filter(e => e.kind === 'design-style')
    await applyAllowlist(pair, cell)
    const rules = await census(pair.design)
    pair.custom = ['--bd-a', ...new Set(rules.filter(r => r.selector && (r.source === 'C' ? ownsBuildLine(r.line) : r.matches.some(m => m.count))).flatMap(r => r.declarations.map(d => d.property).filter(p => p.startsWith('--'))))]
    const data = await pair.design.evaluate(roots => {
      const parent = document.querySelector('#build-root').parentElement
      const style = getComputedStyle(parent)
      const inherit = [...style].filter(p => /^(?:font-|line-height|color$|letter-spacing|text-|visibility|cursor|direction|white-space|-webkit-font-smoothing)/.test(p))
      const inherited = Object.fromEntries(inherit.map(p => [p, parent.computedStyleMap().get(p)?.toString() ?? style.getPropertyValue(p)]))
      const rect = parent.getBoundingClientRect()
      const rootNodes = [...document.querySelectorAll(roots)]
      const scroll = rootNodes.flatMap(root => [root, ...root.querySelectorAll('*')]).map(e => [e.scrollLeft, e.scrollTop])
      return { roots: rootNodes.map(e => e.outerHTML), scroll, html: [...document.documentElement.attributes].map(a => [a.name, a.value]), body: document.body.getAttribute('style'),
        inherited, layout: { display: style.display, flexDirection: style.flexDirection, alignItems: style.alignItems }, width: rect.width - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight) - parseFloat(style.borderLeftWidth) - parseFloat(style.borderRightWidth), left: rect.left + parseFloat(style.paddingLeft), top: rect.top + parseFloat(style.paddingTop),
        htmlStyle: { scrollbarGutter: getComputedStyle(document.documentElement).scrollbarGutter, overflowX: getComputedStyle(document.documentElement).overflowX } }
    }, ROOTS)
    const origin = new URL(test.info().project.use.baseURL).origin
    await guardNetwork(pair.product, [origin])
    await pair.product.route(`${origin}/home-css-transplant`, route => route.fulfill({ contentType: 'text/html', body: '<!doctype html><html><head><link rel="stylesheet" href="/dashboard.css"><link rel="stylesheet" href="/build-home/home.css"></head><body></body></html>' }))
    await pair.product.clock.setFixedTime(FIXTURE_META.now)
    await pair.product.goto(`${origin}/home-css-transplant`)
    await pair.product.evaluate(data => {
      data.html.forEach(([k, v]) => document.documentElement.setAttribute(k, v))
      Object.assign(document.documentElement.style, data.htmlStyle)
      if (data.body) document.body.setAttribute('style', data.body)
      const wrapper = document.createElement('div')
      wrapper.id = 'home-css-wrapper'
      wrapper.style.cssText = `position:absolute;left:${data.left}px;top:${data.top}px;width:${data.width}px;`
      Object.assign(wrapper.style, data.layout)
      Object.entries(data.inherited).forEach(([k, v]) => wrapper.style.setProperty(k, v))
      document.body.append(wrapper)
      for (const html of data.roots) {
        const template = document.createElement('template')
        template.innerHTML = html
        const root = template.content.firstElementChild
        ;(root.id === 'build-root' ? wrapper : document.body).append(root)
      }
      document.querySelectorAll('img[src^="assets/"]').forEach(e => {
        const file = e.getAttribute('src').slice(7)
        const prefix = /^(kimi|deepseek)-logo/.test(file) ? '/build-home/logos/' : '/provider-assets/'
        e.setAttribute('src', prefix + file)
      })
    }, data)
    await pair.product.evaluate(() => document.fonts.ready)
    await pair.product.evaluate(() => document.getAnimations().forEach(a => { if (a instanceof CSSTransition) a.finish() }))
    // Compare identical inert clones so hook listeners cannot turn hover into a DOM change.
    await pair.design.evaluate(({ roots, data }) => {
      const nodes = [...document.querySelectorAll(roots)].map(e => e.cloneNode(true))
      const wrapper = document.createElement('div')
      wrapper.style.cssText = `position:absolute;left:${data.left}px;top:${data.top}px;width:${data.width}px;`
      Object.assign(wrapper.style, data.layout)
      Object.entries(data.inherited).forEach(([k, v]) => wrapper.style.setProperty(k, v))
      document.body.replaceChildren(wrapper)
      nodes.forEach(root => (root.id === 'build-root' ? wrapper : document.body).append(root))
    }, { roots: ROOTS, data })
    for (const page of [pair.design, pair.product]) await page.evaluate(({ roots, scroll }) => {
      [...document.querySelectorAll(roots)].flatMap(root => [root, ...root.querySelectorAll('*')]).forEach((e, i) => { e.scrollLeft = scroll[i][0]; e.scrollTop = scroll[i][1] })
    }, { roots: ROOTS, scroll: data.scroll })
    for (const page of [pair.design, pair.product]) await page.evaluate(() => { document.getAnimations().forEach(a => { a.pause(); a.currentTime = 0 }) })
    return pair
  } catch (error) { await pair.close(); throw error }
}

export function styleSnapshot({ roots, custom = [], reduced = false, index }) {
  const matches = [...document.querySelectorAll(roots)]
  const nodes = (index == null ? matches : [matches[index]]).flatMap(root => [root, ...root.querySelectorAll('*')])
  const excluded = reduced ? ['animation-duration', 'animation-iteration-count', 'transition-duration', 'scroll-behavior'] : []
  const read = style => Object.fromEntries([...style, ...custom].filter(p => !excluded.includes(p) && (!p.startsWith('--') || custom.includes(p))).map(p => [p, style.getPropertyValue(p)]))
  return nodes.map(e => {
    const styles = { element: read(getComputedStyle(e)) }
    for (const pseudo of ['::before', '::after']) {
      const style = getComputedStyle(e, pseudo)
      if (style.content !== 'none' && style.content !== 'normal') styles[pseudo] = read(style)
    }
    return { tag: e.tagName, path: `${e.tagName.toLowerCase()}${e.id ? '#' + e.id : ''}.${[...e.classList].join('.')}`, styles }
  })
}

export async function compareStyles(pair, selectors = ROOTS, index) {
  const options = { roots: selectors, index, custom: pair.custom, reduced: pair.cell.reducedMotion === 'reduce' }
  const [design, product] = await Promise.all([pair.design.evaluate(styleSnapshot, options), pair.product.evaluate(styleSnapshot, options)])
  expect(product.length, 'same cloned node count').toBe(design.length)
  const differences = []
  for (let i = 0; i < design.length; i++) {
    expect(product[i].tag).toBe(design[i].tag)
    for (const pseudo of new Set([...Object.keys(design[i].styles), ...Object.keys(product[i].styles)])) {
      for (const property of new Set([...Object.keys(design[i].styles[pseudo] ?? {}), ...Object.keys(product[i].styles[pseudo] ?? {})])) {
        const expected = design[i].styles[pseudo]?.[property]
        const actual = product[i].styles[pseudo]?.[property]
        if (expected !== actual) differences.push({ state: pair.cell.name, index: i, path: design[i].path, pseudo, property, design: expected, product: actual })
      }
    }
  }
  if (differences.length) await writeFile(test.info().outputPath('home-css-diff.json'), JSON.stringify(differences, null, 2))
  expect(differences.slice(0, 50), `${differences.length} computed-style differences`).toEqual([])
}

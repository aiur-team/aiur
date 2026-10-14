import { readFile, writeFile } from 'node:fs/promises'
import { DESIGN_ROOT } from './design-parity.mjs'

export const ROOTS = '#build-root, #tk-backdrop, body > .ax-pop'
export const DEAD = /(?:\.(?:bd-now-g|bd-mock|bd-tg|bd-prop|bd-m-[\w-]+|bd-now-strip|bd-more|bd-gl|bd-fa|bd-fd|bd-feats|bd-fp|bd-zb|lay-tiles|lay-stack)\b|\.bd-card\.compact\b|\.bd-root\.narrow\b|\.bd-mk\.wave\b|#bd-fit\b|\.bd-card\.line\.gt\b)/
export const buildSource = await readFile(`${DESIGN_ROOT}/assets/build.css`, 'utf8')
export const htmlSource = await readFile(`${DESIGN_ROOT}/Aiur Dashboard.html`, 'utf8')
const inlineStart = htmlSource.indexOf('<style>') + 7
export const inlineSource = htmlSource.slice(inlineStart, htmlSource.indexOf('</style>', inlineStart))
const inlineLine = htmlSource.slice(0, inlineStart).split('\n').length - 1

// Strip state pseudos only; structural selectors remain evidence of actual matches.
export function censusRules({ buildSource, inlineSource, inlineLine, roots, sourceTrees }) {
  const rootsNodes = [...document.querySelectorAll(roots)]
  const inside = e => rootsNodes.some(root => root === e || root.contains(e))
  const results = []
  const matchSelectors = selectors => selectors.map(selector => {
    const query = selector.replace(/:not\(:(?:hover|focus-visible|focus-within|focus|active|visited|disabled|checked)\)/g, '').replace(/::[\w-]+(?:\([^)]*\))?|:(?:hover|focus-visible|focus-within|focus|active|visited|disabled|checked)\b/g, '')
    const usable = query.trim() ? query.replace(/([>+~])\s*$/, '$1 *') : '*'
    const nodes = [...document.querySelectorAll(usable)].filter(inside)
    return { selector, count: nodes.length, elements: [...new Set(nodes.map(e => `${e.tagName.toLowerCase()}${e.id ? '#' + e.id : ''}${e.classList.length ? '.' + [...e.classList].join('.') : ''}${e.dataset.id ? '[data-id="' + e.dataset.id + '"]' : ''}`))] }
  })
  if (sourceTrees) {
    const rematch = rules => rules.forEach(rule => {
      if (rule.children) rematch(rule.children)
      else if (rule.selector) {
        rule.matches = matchSelectors(rule.matches.map(m => m.selector))
        results.push(rule)
      }
    })
    for (const record of JSON.parse(sourceTrees)) { rematch(record.tree); results.push(record) }
    return JSON.stringify(results)
  }
  const declarations = text => {
    const pieces = []
    let start = 0, depth = 0, quote = ''
    for (let i = 0; i <= text.length; i++) {
      const c = text[i]
      if (quote) { if (c === '\\') i++; else if (c === quote) quote = ''; continue }
      if (c === '"' || c === "'") { quote = c; continue }
      if (c === '(') depth++
      if (c === ')') depth--
      if ((c === ';' && !depth) || i === text.length) { pieces.push(text.slice(start, i)); start = i + 1 }
    }
    return pieces.flatMap(piece => {
      const colon = piece.indexOf(':')
      if (colon < 0) return []
      const property = piece.slice(0, colon).trim()
      const raw = piece.slice(colon + 1).trim()
      const priority = /!important\s*$/.test(raw) ? 'important' : ''
      const value = raw.replace(/\s*!important\s*$/, '')
      // Preserve the source's Safari blur fallback even when Chromium drops the prefix.
      return property === '-webkit-backdrop-filter' || CSS.supports(property, value) ? [{ property, value, priority }] : []
    })
  }
  for (const [source, text, offset] of [['H', inlineSource, inlineLine], ['C', buildSource, 0]]) {
    const sheet = new CSSStyleSheet()
    sheet.replaceSync(text)
    const clean = text.replace(/\/\*[\s\S]*?\*\//g, comment => comment.replace(/[^\n]/g, ' '))
    const headers = []
    for (const match of clean.matchAll(/([^{}]+)\{/g)) {
      const header = match[1].trim()
      if (!header || header.startsWith('@')) continue
      const probe = new CSSStyleSheet()
      probe.replaceSync(`${header} {}`)
      const selector = probe.cssRules[0]?.selectorText
      if (selector) headers.push({ selector, declarations: declarations(clean.slice(match.index + match[0].length, clean.indexOf('}', match.index + match[0].length))), line: offset + clean.slice(0, match.index + match[1].indexOf(header)).split('\n').length })
    }
    let cursor = 0
    const walk = (rules, context = []) => [...rules].map(rule => {
      if (rule.selectorText) {
        const index = headers.findIndex((h, i) => i >= cursor && h.selector === rule.selectorText)
        if (index < 0) throw Error(`source line missing: ${source} ${rule.selectorText}`)
        cursor = index + 1
        const selectors = rule.selectorText.split(/,(?![^()]*\))/).map(s => s.trim())
        const matches = matchSelectors(selectors)
        const entry = { source, line: headers[index].line, selector: rule.selectorText, context, matches,
          declarations: headers[index].declarations }
        results.push(entry)
        return entry
      }
      if (rule.type === CSSRule.KEYFRAMES_RULE || rule.constructor.name === 'CSSPropertyRule') {
        return { source, at: rule.cssText, name: rule.name }
      }
      if (rule.cssRules) return { source, group: rule.cssText.slice(0, rule.cssText.indexOf('{')).trim(), children: walk(rule.cssRules, [...context, rule.cssText.slice(0, rule.cssText.indexOf('{')).trim()]) }
      return null
    }).filter(Boolean)
    results.push({ source, tree: walk(sheet.cssRules) })
  }
  return JSON.stringify(results)
}

// Immutable design syntax is parsed once per worker; DOM matches are recomputed in every state.
let sourceTrees
export async function census(page) {
  const records = JSON.parse(await page.evaluate(censusRules, sourceTrees
    ? { sourceTrees, roots: ROOTS }
    : { buildSource, inlineSource, inlineLine, roots: ROOTS }))
  sourceTrees ??= JSON.stringify(records.filter(r => r.tree))
  return records
}

export function ownsBuildLine(line) {
  return [[29, 32], [49, 898], [930, 990], [1010, 1026], [1050, 1066], [1078, 1140], [1148, 1193]].some(([a, b]) => line >= a && line <= b)
}

export function renderHomeCss(records) {
  const matched = new Set(records.filter(r => r.selector && r.matches.some(m => m.count)).map(r => `${r.source}:${r.line}:${r.selector}`))
  const shadowed = []
  const rows = records.find(r => r.source === 'C' && r.tree).tree
  const inline = records.find(r => r.source === 'H' && r.tree).tree
  const selected = []
  const scope = ':where(.bd-root, .tk-backdrop, .ax-pop)'
  const select = rules => rules.flatMap(rule => {
    if (rule.children) { const children = select(rule.children); return children.length ? [{ ...rule, children }] : [] }
    if (rule.at) return rule.source === 'C' || ['khSpin', 'tkin'].includes(rule.name) ? [rule] : []
    const utility = rule.source === 'H' && ['.mono', '.num'].includes(rule.selector)
    if (rule.source === 'C' ? !ownsBuildLine(rule.line) : (!utility && !matched.has(`H:${rule.line}:${rule.selector}`)) || /^(?:\*|html|body|:root)$/.test(rule.selector) || rule.line === 150 || rule.selector.startsWith(':root') || rule.selector.startsWith('html[data-palette')) return []
    const selectors = rule.matches.filter(m => !DEAD.test(m.selector) && !(rule.source === 'C' && rule.line === 983 && m.selector.includes('.ax-menu')) && (rule.source === 'C' || utility || m.count)).map(m => m.selector)
    if (!selectors.length) return []
    const selector = selectors.map(s => {
      if (rule.source === 'C' || s.startsWith('.tk-')) return s
      // Inserting :where immediately before the target retains html theme conditions.
      const head = s.match(/^html\[[^\]]+\]\s+/)?.[0] ?? ''
      return `${head}${scope} ${s.slice(head.length)}`
    }).join(', ')
    const entry = { ...rule, selector, declarations: rule.declarations.map(d => ({ ...d })) }
    if (rule.source === 'H' && rule.selector === '.btn') entry.declarations.push({ property: 'justify-content', value: 'normal' }, { property: 'min-height', value: 'auto' })
    if (rule.source === 'H' && ['a', 'button'].includes(rule.selector)) entry.declarations.push({ property: '-webkit-tap-highlight-color', value: 'initial' })
    selected.push(entry)
    return [entry]
  })
  const tree = [...select(inline), ...select(rows)]
  // Never fold across a media/container context or selectors of different specificity.
  for (let i = 0; i < selected.length; i++) {
    const early = selected[i]
    early.declarations = early.declarations.filter(d => {
      const late = selected.slice(i + 1).find(r => r.selector === early.selector && JSON.stringify(r.context) === JSON.stringify(early.context) && r.declarations.some(next => next.property === d.property && (d.priority !== 'important' || next.priority === 'important')))
      if (late && !/var\(--(?:ph|pct),/.test(d.value)) shadowed.push({ source: early.source, line: early.line, selector: early.selector, property: d.property, supersededBy: { source: late.source, line: late.line } })
      return !late || /var\(--(?:ph|pct),/.test(d.value)
    })
  }
  const blocks = []
  const format = (text, depth = 0) => {
    const lines = []
    let token = '', quote = '', parens = 0
    const flush = () => { if (token.trim()) lines.push('  '.repeat(depth) + token.trim()); token = '' }
    for (let i = 0; i < text.length; i++) {
      const c = text[i]
      if (quote) { token += c; if (c === '\\') token += text[++i]; else if (c === quote) quote = ''; continue }
      if (c === '"' || c === "'") quote = c
      if (c === '(') parens++
      if (c === ')') parens--
      if (!parens && c === '{') { token = token.trimEnd() + ' {'; flush(); depth++ }
      else if (!parens && c === '}') { flush(); depth--; token = '}'; flush() }
      else if (!parens && c === ';') { token += c; flush() }
      else token += c
    }
    flush()
    return lines.join('\n') + '\n'
  }
  const render = rules => rules.flatMap(r => {
    if (r.children) return [`${r.group} { ${render(r.children).join(' ')} }`]
    if (r.at) return [r.at]
    if (!r.declarations.length) return []
    return [`/* ${r.source}:${r.line} */ ${r.selector} { ${r.declarations.map(d => `${d.property}: ${d.property === 'color' && d.value === 'rgb(255, 255, 255)' ? '#fff' : d.value}${d.priority ? ' !' + d.priority : ''};`).join(' ')} }`]
  })
  const collect = (rules, contexts = []) => rules.forEach(r => {
    const text = [...contexts.map(c => `${c} {`), ...render([r]), ...contexts.map(() => '}')].join(' ')
    if (r.children && format(text).split('\n').length > 450) collect(r.children, [...contexts, r.group])
    else if (render([r]).length) blocks.push({ source: r.source, line: r.line ?? r.children?.find(child => child.line)?.line ?? 0, text: format(text) })
  })
  blocks.push({ source: 'H', line: 0, text: format(`${scope} textarea { font: revert; }`) })
  collect(tree)
  const section = r => r.source === 'H' ? r.line < 200 ? 'base' : r.line < 1500 ? 'buttons' : 'ticket-modal' :
    r.line < 303 ? 'build-cards' : r.line < 450 ? 'build-states' : r.line < 611 ? 'conversation' :
      r.line < 730 ? 'tree-modal' : r.line < 899 ? 'list-models' : r.line < 1027 ? 'responsive-light' : 'palette-fixes'
  const parts = {}
  let previous = '', count = 0, name = '', lines = 0
  for (const block of blocks) {
    const label = block.line ? section(block) : previous || 'base'
    const length = block.text.trimEnd().split('\n').length + 1
    if (label !== previous || lines + length > 450) {
      previous = label; count++; name = `${String(count).padStart(2, '0')}-${label}.css`; lines = 0
      parts[name] = ''
    }
    parts[name] += block.text + '\n'; lines += length
  }
  const css = '/* Design etag 1791431544512943. Do not restyle; regenerate parity on every change. */\n' +
    Object.keys(parts).map(name => `@import url("home/${name}");`).join('\n') + '\n'
  return { css, parts, shadowed }
}

export async function writeHomeCensus(states, outputPath) {
  if (!states.length) return
  const all = []
  const combined = new Map()
  const key = r => `${r.source}:${r.line}:${r.selector}:${JSON.stringify(r.context)}`
  let trees
  for (const { state, records } of states) {
    all.push({ state, rules: structuredClone(records.filter(r => r.selector)) })
    for (const rule of records.filter(r => r.selector)) {
      if (!combined.has(key(rule))) combined.set(key(rule), structuredClone(rule))
      else rule.matches.forEach((m, i) => { combined.get(key(rule)).matches[i].count += m.count })
    }
    trees ??= structuredClone(records.filter(r => r.tree))
  }
  const update = rules => rules.forEach(r => r.children ? update(r.children) : r.selector ? Object.assign(r, combined.get(key(r))) : null)
  trees.forEach(r => update(r.tree))
  const records = [...combined.values(), ...trees]
  const { css, parts, shadowed } = renderHomeCss(records)
  const dead = records.filter(r => r.selector).flatMap(r => r.matches.filter(m => DEAD.test(m.selector)).map(m => ({ source: r.source, line: r.line, ...m })))
  const zeroMatches = records.filter(r => r.source === 'C' && r.selector && ownsBuildLine(r.line)).flatMap(r => r.matches.filter(m => !m.count && !DEAD.test(m.selector) && !(r.line === 983 && m.selector.includes('.ax-menu'))).map(m => ({ source: r.source, line: r.line, context: r.context, ...m })))
  await writeFile(outputPath, JSON.stringify({ states: all, dead, zeroMatches, shadowed, css, parts, trees }, null, 2))
}

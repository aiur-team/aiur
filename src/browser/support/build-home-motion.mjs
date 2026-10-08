// Motion records use the same allowlist as screenshot parity. Design bytes stay untouched.
const wildcard = path => new RegExp(`^${path.split('*').map(part => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*')}$`)
const geometry = /(?:scrollTop|top|left|width|height)$/

function equalValue(design, product, path) {
  if (Object.is(design, product)) return true
  if (typeof design === 'number' && typeof product === 'number') {
    const tolerance = geometry.test(path) ? 1 : path.endsWith('opacity') ? 0.001 : 0
    return Number.isFinite(design) && Number.isFinite(product) && Math.abs(design - product) <= tolerance
  }
  if (typeof design !== 'string' || typeof product !== 'string') return false
  if (geometry.test(path) && /^-?[\d.]+px$/.test(design) && /^-?[\d.]+px$/.test(product)) return Math.abs(parseFloat(design) - parseFloat(product)) <= 1
  if (!path.endsWith('transform') || !design.startsWith('matrix') || !product.startsWith('matrix')) return false
  const values = value => value.slice(value.indexOf('(') + 1, -1).split(',').map(Number)
  const a = values(design), b = values(product)
  return a.length === b.length && a.every((value, i) => Number.isFinite(value) && Number.isFinite(b[i]) && Math.abs(value - b[i]) <= 0.01)
}

function differences(design, product, path, result) {
  if (equalValue(design, product, path)) return
  if (design === null || product === null || typeof design !== 'object' || typeof product !== 'object' || Array.isArray(design) !== Array.isArray(product)) {
    result.push({ path, design, product }); return
  }
  for (const key of new Set([...Object.keys(design), ...Object.keys(product)])) {
    differences(design[key], product[key], Array.isArray(design) ? `${path}[${key}]` : `${path}.${key}`, result)
  }
}

export function compareRecords(design, product, allowlist = []) {
  const name = design?.name ?? product?.name ?? 'record'
  if (!design?.samples?.length || !product?.samples?.length) return [{ path: name, reason: 'unreachable' }]
  const result = []
  differences(design, product, name, result)
  const entries = allowlist.filter(entry => entry.kind === 'motion' && entry.path.startsWith(`${name}.`))
  for (const entry of entries) {
    const matches = result.filter(diff => wildcard(entry.path).test(diff.path))
    if (!matches.length) throw new Error(`stale allowlist entry ${entry.id}`)
    if (entry.approval.status !== 'approved' && entry.approval.status !== 'pending-sign-off') throw new Error(`unapproved motion entry ${entry.id}`)
  }
  return result.filter(diff => !entries.some(entry => wildcard(entry.path).test(diff.path)))
}

export async function domState(page, ids = {}) {
  return page.evaluate(ids => {
    const reverse = Object.fromEntries(Object.entries(ids).map(([design, product]) => [product, design]))
    const nodes = [...document.querySelectorAll('.bd-card, .bd-lane, .bd-guide, .bd-mk')].map((el, index) => ({
      key: reverse[el.dataset.id] ?? el.dataset.id ?? `${el.classList.contains('bd-lane') ? 'lane' : el.classList.contains('bd-guide') ? 'guide' : 'mark'}:${el.title || index}`,
      classes: [...el.classList].filter(token => !token.startsWith('phx-')).sort(),
      ...Object.fromEntries(['top', 'left', 'width', 'height'].map(property => [property, el.style[property]]))
    }))
    return { nodes, query: [...new URLSearchParams(location.search)].sort(), scrollTop: document.querySelector('#bd-vp')?.scrollTop ?? null }
  }, ids)
}

export async function scrollFrames(page, { from, frames = 27 }) {
  if (from !== undefined) await page.locator('#bd-vp').evaluate((el, from) => new Promise(resolve => {
    if (el.scrollTop === from) return resolve()
    el.addEventListener('scroll', resolve, { once: true }); el.scrollTop = from
  }), from)
  const samples = []
  for (let frame = 0; frame < frames; frame++) {
    await page.clock.runFor(16)
    samples.push(await page.locator('#bd-vp').evaluate(el => ({ scrollTop: el.scrollTop })))
  }
  return samples
}

export async function pausedAnimations(page, selector, { trigger, reducedMotion = false } = {}) {
  return page.evaluate(({ selector, trigger, reducedMotion }) => {
    if (trigger) {
      const input = document.querySelector(trigger)
      if (!input) throw new Error(`unreachable input: ${trigger}`)
      input.click()
    }
    const root = document.querySelector(selector)
    if (!root) throw new Error(`unreachable measurement: ${selector}`)
    // Flush the style change and pause in this same task, before any paint.
    getComputedStyle(root).opacity
    return root.getAnimations({ subtree: true }).map(animation => {
      const effect = animation.effect, el = effect.target
      const timing = effect.getTiming(), name = animation.animationName ?? animation.transitionProperty ?? animation.id
      const playState = animation.playState
      animation.pause()
      if (reducedMotion && Number(timing.duration) < 50) return null
      const samples = [0, 0.25, 0.5, 0.75, 1].map(fraction => {
        animation.currentTime = Number(timing.delay) + Number(timing.duration) * fraction
        const style = getComputedStyle(el, effect.pseudoElement)
        return Object.fromEntries(['opacity', 'transform', 'left', 'width', 'filter'].map(property => [property, property === 'opacity' ? Number(style[property]) : style[property]]))
      })
      animation.currentTime = 0
      return { name, target: el.id || el.dataset.id || el.className, pseudo: effect.pseudoElement ?? null, playState,
        timing: { ...timing, iterations: timing.iterations === Infinity ? 'infinite' : timing.iterations }, keyframes: effect.getKeyframes(), samples }
    }).filter(Boolean)
  }, { selector, trigger, reducedMotion })
}

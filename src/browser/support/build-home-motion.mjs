// The ticket requires one support module: measurements and sequence ownership stay together.
// Motion records use the same allowlist as screenshot parity. Design bytes stay untouched.
import { captureStable } from './design-parity.mjs'
export const motionPathMatches = (pattern, path) => new RegExp(`^${pattern.split('*').map(part => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*')}$`).test(path.replace(/^reduce\.live-toggle\.animation\.tkin(?=\.)/, 'modal.reduce.animation.tkin'))
const geometry = /(?:scrollTop|top|left|width|height)$/

function equalValue(design, product, path) {
  if (Object.is(design, product)) return true
  if (typeof design === 'number' && typeof product === 'number') {
    const tolerance = /^columns\..*\.(?:applyAt|removeAt|samples\[\d+\]\.at)$/.test(path) ? 16 : geometry.test(path) ? 1 : path.endsWith('opacity') ? 0.001 : 0
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
  const present = design === undefined ? product : product === undefined ? design : null
  if (present && typeof present === 'object') {
    for (const key of Object.keys(present)) differences(design?.[key], product?.[key], Array.isArray(present) ? `${path}[${key}]` : `${path}.${key}`, result)
    return
  }
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
  // Column timers may cross a sampling boundary by one frame; retain every state change.
  if (name.startsWith('columns.')) {
    const changes = samples => samples.flatMap((state, index) => index === 0 || JSON.stringify(state) !== JSON.stringify(samples[index - 1]) ? [{ at: (index + 1) * 16, state }] : [])
    design = { ...design, samples: changes(design.samples) }
    product = { ...product, samples: changes(product.samples) }
  }
  differences(design, product, name, result)
  const entries = allowlist.filter(entry => entry.kind === 'motion' && (entry.path === '*' || entry.path.startsWith(`${name}.`) || (name === 'reduce.live-toggle' && entry.path.startsWith('modal.reduce.animation.tkin.'))))
  for (const entry of entries) {
    const matches = result.filter(diff => motionPathMatches(entry.path, diff.path))
    if (!matches.length) throw new Error(`stale allowlist entry ${entry.id}`)
    if (entry.approval.status !== 'approved' && entry.approval.status !== 'pending-sign-off') throw new Error(`unapproved motion entry ${entry.id}`)
  }
  return result.filter(diff => !entries.some(entry => motionPathMatches(entry.path, diff.path)))
}

export async function domState(page, ids = {}) {
  return page.evaluate(ids => {
    const reverse = Object.fromEntries(Object.entries(ids).map(([design, product]) => [product, design]))
    const lanes = [...document.querySelectorAll('.bd-lane')]
    const guides = [...document.querySelectorAll('.bd-guide')]
    const nodes = [...document.querySelectorAll('.bd-card, .bd-lane, .bd-guide, .bd-mk')].map((el, index) => ({
      key: el.dataset.id ? `card:${reverse[el.dataset.id] ?? el.dataset.id}` : el.classList.contains('bd-lane') ? `lane:${el.title}` : el.classList.contains('bd-guide') ? `guide:${lanes[guides.indexOf(el)]?.title ?? guides.indexOf(el)}` : `mark:${el.closest('section')?.id}:${index}`,
      classes: [...el.classList].filter(token => !token.startsWith('phx-')).sort(),
      ...Object.fromEntries(['top', 'left', 'width', 'height'].map(property => [property, el.style[property]]))
    }))
    if (new Set(nodes.map(node => node.key)).size !== nodes.length) throw new Error('duplicate motion DOM key')
    // example selects only the design mock; the product uses the fixture route.
    return { nodes: Object.fromEntries(nodes.map(node => [node.key, node])), query: [...new URLSearchParams(location.search)].filter(([key]) => key !== 'example').map(([key, value]) => [key, key === 'ticket' ? reverse[value] ?? value : value]).sort(), scrollTop: document.querySelector('#bd-vp')?.scrollTop ?? null }
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

export async function pausedAnimations(page, selector, { trigger, event = 'click', reducedMotion = false, inventoryOnly = false } = {}) {
  return page.evaluate(({ selector, trigger, event, reducedMotion, inventoryOnly }) => {
    if (trigger) {
      const input = document.querySelector(trigger)
      if (!input) throw new Error(`unreachable input: ${trigger}`)
      if (event === 'pointerdown') input.dispatchEvent(new PointerEvent(event, { bubbles: true, pointerId: 1 }))
      else input.click()
    }
    const roots = [...document.querySelectorAll(selector)]
    const root = roots[0]
    if (!root) throw new Error(`unreachable measurement: ${selector}`)
    // Flush the style change and pause in this same task, before any paint.
    getComputedStyle(root).opacity
    const animations = [...new Set(roots.flatMap(el => el.getAnimations({ subtree: true })))]
    const states = new Map(animations.map(animation => [animation, animation.playState]))
    animations.forEach(animation => animation.pause())
    window.motionAnimations = animations.filter(animation => !reducedMotion || Number(animation.effect.getTiming().duration) >= 50)
    for (const animation of animations) if (!window.motionAnimations.includes(animation)) {
      const timing = animation.effect.getTiming()
      animation.currentTime = Number(timing.delay) + Number(timing.duration)
    }
    // Sample the composed styles with every animation at the same fraction.
    const samples = new Map(window.motionAnimations.map(animation => [animation, []]))
    for (const fraction of inventoryOnly ? [] : [0, .25, .5, .75, 1]) {
      window.motionAnimations.forEach(animation => {
        const timing = animation.effect.getTiming()
        animation.currentTime = Number(timing.delay) + Number(timing.duration) * fraction
      })
      window.motionAnimations.forEach(animation => {
        const effect = animation.effect, style = getComputedStyle(effect.target, effect.pseudoElement)
        samples.get(animation).push(Object.fromEntries(['opacity', 'transform', 'left', 'width', 'filter'].map(property => [property, property === 'opacity' ? Number(style[property]) : style[property]])))
      })
    }
    return window.motionAnimations.map(animation => {
      const effect = animation.effect, el = effect.target, timing = effect.getTiming()
      animation.currentTime = 0
      return { name: animation.animationName ?? animation.transitionProperty ?? animation.id,
        target: el.id || el.dataset.id || el.getAttribute('class') || el.localName, pseudo: effect.pseudoElement ?? null, playState: states.get(animation),
        timing: { ...timing, iterations: timing.iterations === Infinity ? 'infinite' : timing.iterations },
        ...(inventoryOnly ? {} : { keyframes: effect.getKeyframes(), samples: samples.get(animation) }) }
    })
  }, { selector, trigger, event, reducedMotion, inventoryOnly })
}

export const OWNER = {
  'snap.scroll-curve': { owners: ['MP-E8-C9-T08', 'MP-E8-C10-T01', 'MP-E8-C9-T10'], anchor: '#bd-nowbtn' },
  'snap': { owners: ['MP-E8-C9-T08'], anchor: '.bd-now-h > b' },
  'columns': { owners: ['MP-E8-C9-T04', 'MP-E8-C9-T10'], anchor: '.bd-content .bd-lane' },
  'view.span': { owners: ['MP-E8-C9-T10'], anchor: '.bd-zoom [data-z]' },
  'view.switch.graph': { owners: ['MP-E8-C10-T01'], pending: true },
  'view.switch.gantt': { owners: ['MP-E8-C9-T09'], pending: true },
  'view.switch.list': { owners: ['MP-E8-C9-T12'], pending: true },
  'filter': { owners: ['MP-E8-C10-T02'], anchor: '.bd-fg' },
  'feature': { owners: ['MP-E8-C10-T03'], pending: true, anchor: '.bd-fg[data-g="feature"]' },
  'modal': { owners: ['MP-E8-C11-T01'], anchor: '#tk-modal.bdm' },
  'minimap': { owners: ['MP-E8-C11-T05'], pending: true, anchor: '#tk-modal.bdm' },
  'tree': { owners: ['MP-E8-C9-T11'], anchor: '#build-root[data-bd-trees="ready"]' },
  // The C3-T01 skeleton already has .bd-spin; it cannot prove C9-T13's styles exist.
  'loading.spin': { owners: ['MP-E8-C9-T13'], pending: true },
  'reduce.live-toggle': { owners: ['MP-E8-C9-T08', 'MP-E8-C11-T01'], anchor: 'html:has(.bd-now-h > b):has(#tk-modal.bdm)' },
  'grain.static': { per: { '.bd-now': 'MP-E8-C9-T08', '.bd-content .bd-lanes': 'MP-E8-C9-T04', '.ax-uc': 'MP-E8-C10-T04' } },
  'inventory': { per: { '.bd-glow, .bd-ag': 'MP-E8-C9-T06', '.bd-now-h > b i': 'MP-E8-C9-T08', '.bd-live i': 'MP-E8-C10-T01', '.bd-skel i': 'MP-E8-C9-T13' } }
}

export async function runOn(page, name, ctx = {}) {
  if (!SEQUENCES[name]) throw new Error(`unknown motion sequence ${name}`)
  try {
    const result = await SEQUENCES[name](page, ctx)
    const recordName = ctx.reduce && name === 'loading.spin' ? 'loading.spin.reduce' : ctx.reduce && ['modal.open', 'modal.reduce', 'modal.url'].includes(name) ? 'modal.reduce' : name
    return { name: recordName, ...result }
  } catch (error) {
    if (!error.message.startsWith('unreachable')) throw error
    return { name, samples: [], reason: error.message }
  }
}

async function click(page, selector, waitScroll = false) {
  if (!await page.locator(selector).count()) throw new Error(`unreachable input: ${selector}`)
  await page.locator(selector).first().evaluate((el, waitScroll) => {
    if (!waitScroll) return el.click()
    const vp = document.querySelector('#bd-vp'), before = vp.scrollTop
    return new Promise(resolve => {
      const done = () => { vp.removeEventListener('scroll', done); resolve() }
      vp.addEventListener('scroll', done); el.click()
      if (vp.scrollTop === before) done()
    })
  }, waitScroll)
}

const state = (page, ctx) => domState(page, ctx.ids)
async function cssMotion(page, selector, ctx, trigger) {
  const animations = await pausedAnimations(page, selector, { trigger, event: ctx.triggerEvent, reducedMotion: ctx.reduce, inventoryOnly: ctx.inventoryOnly })
  const reverse = Object.fromEntries(Object.entries(ctx.ids ?? {}).map(([design, product]) => [product, design]))
  for (const animation of animations) animation.target = reverse[animation.target] ?? animation.target
  for (const fraction of [0, .5, 1]) {
    await page.evaluate(fraction => window.motionAnimations?.forEach(animation => {
      const timing = animation.effect.getTiming()
      animation.currentTime = Number(timing.delay) + Number(timing.duration) * fraction
    }), fraction)
    await ctx.onFrame?.(fraction, selector)
  }
  animations.sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)))
  return Object.fromEntries(animations.map(({ name, timing, ...animation }, index) => [animations.filter(a => a.name === name).length > 1 ? `${name}[${index}]` : name, { ...timing, ...animation }]))
}

async function scrollTo(page, value) {
  return page.locator('#bd-vp').evaluate((el, value) => new Promise(resolve => {
    const previous = el.scrollTop
    el.addEventListener('scroll', () => resolve(performance.now()), { once: true })
    el.scrollTop = Math.max(0, Math.min(value, el.scrollHeight - el.clientHeight))
    if (previous === el.scrollTop) resolve(performance.now())
  }), value)
}

async function snap(page, ctx, kind) {
  if (kind === 'list-view') await click(page, '[data-v="list"]')
  const geometry = await page.evaluate(() => {
    const vp = document.querySelector('#bd-vp'), band = document.querySelector('#bd-now')
    if (!vp || (!band && !document.querySelector('.bd-list'))) throw new Error('unreachable snap viewport')
    const hist = document.querySelector('#bd-sec-hist'), natural = hist ? hist.offsetTop + hist.offsetHeight : 0
    return { top: band ? natural - 46 : 0, bottom: band ? natural + band.offsetHeight - vp.clientHeight : 0,
      tallHeight: band ? band.offsetHeight + 40 : 0 }
  })
  if (kind === 'tall-band') {
    await page.locator('#bd-vp').evaluate((el, height) => { el.style.height = `${height}px`; el.style.maxHeight = `${height}px` }, geometry.tallHeight)
    await page.clock.runFor(160)
  }
  await scrollTo(page, kind.includes('bottom') || kind === 'guard-down' ? geometry.bottom : geometry.top)
  await page.clock.runFor(704)
  const start = await page.locator('#bd-vp').evaluate(el => el.scrollTop)
  const delta = kind === 'pinned' ? -1 : kind === 'guard-up' ? -100 : kind === 'guard-down' ? 100 : kind.includes('bottom') ? 20 : -20
  await scrollTo(page, start + delta)
  const frame = [{ scrollTop: await page.locator('#bd-vp').evaluate(el => el.scrollTop) }]
  await ctx.onFrame?.(0, '#bd-vp')
  for (let i = 0; i < 40; i++) {
    await page.clock.runFor(16)
    frame.push({ scrollTop: await page.locator('#bd-vp').evaluate(el => el.scrollTop) })
    if (i === 19 || i === 39) await ctx.onFrame?.((i + 1) / 40, '#bd-vp')
  }
  return { samples: [await state(page, ctx)], frame }
}

async function scrollCurve(page, ctx) {
  await click(page, '.bd-cal [data-span="7"]')
  await page.clock.runFor(16)
  await page.clock.runFor(704)
  // A tall band disables liveGuard so it cannot restart the curve midway through.
  await page.locator('#bd-vp').evaluate(el => {
    el.style.height = el.style.maxHeight = `${document.querySelector('#bd-now').offsetHeight + 40}px`
  })
  await scrollTo(page, 270)
  await page.clock.runFor(704)
  const input = await page.evaluate(() => ({ from: document.querySelector('#bd-vp').scrollTop,
    to: document.querySelector('#bd-sec-hist').offsetTop + document.querySelector('#bd-sec-hist').offsetHeight - 46, at: performance.now() }))
  await click(page, '#bd-nowbtn')
  await ctx.onFrame?.(0, '#bd-vp')
  const frame = []
  for (let index = 0; index < 27; index++) {
    await page.evaluate(() => requestAnimationFrame(now => { window.motionFrameStamp = now }))
    await page.clock.runFor(16)
    frame.push(await page.evaluate(at => ({ scrollTop: document.querySelector('#bd-vp').scrollTop, elapsed: window.motionFrameStamp - at }), input.at))
    if (index === 12 || index === 26) await ctx.onFrame?.(index === 12 ? .5 : 1, '#bd-vp')
  }
  return { samples: [await state(page, ctx)], frame, input: { from: input.from, to: input.to } }
}

async function scrollbarDrag(page, ctx) {
  const thumb = page.locator('#bd-sb i'), box = await thumb.boundingBox()
  if (!box) throw new Error('unreachable scrollbar thumb')
  const vp = await page.locator('#bd-vp').evaluate(el => ({ scrollTop: el.scrollTop, range: el.scrollHeight - el.clientHeight }))
  const track = await page.locator('#bd-sb').boundingBox()
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
  await page.mouse.down()
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2 - 100 / vp.range * (track.height - box.height))
  await page.clock.runFor(304)
  const during = await state(page, ctx)
  await page.mouse.up()
  await page.clock.runFor(704)
  const after = await state(page, ctx)
  if (Math.abs(after.scrollTop - during.scrollTop) > 1) throw new Error('scrollbar drag snapped after release')
  return { samples: [during, after] }
}

async function columns(page, ctx) {
  if (await page.locator('#bd-content').evaluate(el => el.classList.contains('flow'))) return { samples: [await state(page, ctx)], mode: 'flow' }
  // Month loads older days; week zoom preserves them without paging during measurement.
  await click(page, '.bd-cal [data-span="7"]')
  await page.clock.runFor(16)
  await page.clock.runFor(704)
  const samples = [], initial = await page.locator('.bd-lane:not(.leave)').evaluateAll(nodes => nodes.map(el => el.title))
  await scrollTo(page, 270)
  let applyAt = null, removeAt = null, leaving = false, animation = {}
  for (let elapsed = 16; elapsed <= 800; elapsed += 16) {
    await page.clock.runFor(16)
    const lanes = await page.locator('.bd-lane').evaluateAll(nodes => nodes.map(el => ({ key: el.title, classes: [...el.classList].sort(), left: el.style.left, width: el.style.width })))
    const current = lanes.filter(lane => !lane.classes.includes('leave')).map(lane => lane.key), leave = lanes.some(lane => lane.classes.includes('leave'))
    if (applyAt === null && JSON.stringify(current) !== JSON.stringify(initial)) {
      applyAt = elapsed; animation = await cssMotion(page, '.bd-lanes', ctx)
    }
    if (leave) leaving = true
    if (leaving && !leave && removeAt === null) removeAt = elapsed
    samples.push(Object.fromEntries(lanes.map(lane => [lane.key, lane])))
  }
  if (applyAt === null || removeAt === null) throw new Error(`unreachable column enter/leave ${JSON.stringify({ initial, applyAt, removeAt, final: await page.locator('.bd-lane').allTextContents() })}`)
  return { samples, dom: await state(page, ctx), applyAt, removeAt, animation }
}

async function view(page, ctx, mode) {
  if (mode !== 'span') {
    if (mode === 'graph') await click(page, '[data-v="list"]')
    await click(page, `[data-v="${mode}"]`, true)
    await page.clock.runFor(32)
    return { samples: [await state(page, ctx)] }
  }
  const input = ctx.inputSelector ?? '.bd-cal [data-span]'
  if (!await page.locator(input).count()) throw new Error(`unreachable input: ${input}`)
  const samples = []
  for (const span of await page.locator(input).evaluateAll(nodes => nodes.map(el => el.dataset.span))) {
    await click(page, `.bd-cal [data-span="${span}"]`, true); await page.clock.runFor(32)
    samples.push(await state(page, ctx))
  }
  for (const direction of ['1', '-1']) for (let step = 0; step < 30; step++) {
    const button = page.locator(`.bd-zoom [data-z="${direction}"]`)
    if (!await button.count()) throw new Error('unreachable zoom control')
    const disabled = await button.isDisabled()
    samples.push({ ...await state(page, ctx), disabled })
    if (disabled) break
    await click(page, `.bd-zoom [data-z="${direction}"]`, true); await page.clock.runFor(32)
    if (step === 29) throw new Error('zoom did not reach its endpoint')
  }
  return { samples }
}

async function filter(page, ctx, kind) {
  await click(page, `.bd-fg[data-g="${kind === 'dim' ? 'model' : 'feature'}"]`)
  if (!await page.locator('.bd-opt').count()) throw new Error('unreachable filter options')
  const animation = await cssMotion(page, '#build-root', ctx, '.bd-opt')
  const samples = [await state(page, ctx)]
  if (kind === 'compact') { await click(page, '[data-m="compact"]'); await page.clock.runFor(32); samples.push(await state(page, ctx)) }
  if (kind !== 'dim') { await click(page, '#bd-fx'); await page.clock.runFor(32); samples.push(await state(page, ctx)) }
  return { samples, animation }
}

async function modal(page, ctx, close = false, fromUrl = false) {
  if (fromUrl && !await page.locator('#tk-backdrop.show').count()) throw new Error('unreachable URL-opened modal')
  const animation = await cssMotion(page, '#tk-modal', ctx, fromUrl ? undefined : '.bd-card.now')
  if (!ctx.reduce && !animation.tkin) throw new Error('unreachable tkin animation')
  const count = await page.locator('#cv-log > *').count()
  const samples = [await state(page, ctx)]
  if (close) for (const method of ['button', 'escape', 'backdrop']) {
    if (!await page.locator('#tk-backdrop.show').count()) await click(page, '.bd-card.now')
    if (method === 'button') await click(page, '#bd-tk-close')
    if (method === 'escape') await page.keyboard.press('Escape')
    if (method === 'backdrop') await page.locator('#tk-backdrop').evaluate(el => el.click())
    await page.evaluate(() => Promise.resolve())
    samples.push(await page.evaluate(() => ({ show: document.querySelector('#tk-backdrop').classList.contains('show'),
      overflow: document.body.style.overflow, query: [...new URLSearchParams(location.search)].filter(([key]) => key !== 'example').sort(), animations: document.querySelector('#tk-backdrop').getAnimations({ subtree: true }).length })))
  }
  if (!close && count !== await page.locator('#cv-log > *').count()) throw new Error('live conversation changed during measured window')
  return close ? { samples } : { samples, animation }
}

async function tree(page, ctx) {
  await page.clock.runFor(704)
  const cards = page.locator('.bd-card:not(.now)')
  if (!await cards.count()) throw new Error('unreachable tree card')
  await cards.first().evaluate(el => el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true })))
  await click(page, '[data-lt="lock"]')
  if (!await page.locator('.bd-lt.show.locked').count()) throw new Error('unreachable locked tree control')
  const animation = await cssMotion(page, '#bd-tree', ctx, '[data-lt="tree"]')
  if (await page.locator('#bd-tree').evaluate(el => el.hidden)) throw new Error('unreachable open tree overlay')
  if (!ctx.reduce && !animation.bdTreeIn) throw new Error('unreachable bdTreeIn animation')
  const samples = [await page.locator('#bd-tree').evaluate(el => ({ hidden: el.hidden, backdropFilter: getComputedStyle(el).backdropFilter }))]
  await page.keyboard.press('Escape')
  samples.push(await page.locator('#bd-tree').evaluate(el => ({ hidden: el.hidden })))
  return { samples, animation }
}

async function minimap(page, ctx, jump) {
  await modal(page, { ...ctx, onFrame: undefined })
  await page.clock.runFor(32)
  const initialCount = await page.locator('#cv-log > *').count(), samples = []
  let animation = {}
  if (jump) {
    // Native smooth scrolling uses browser time; wait for the actual scrollend event.
    await page.evaluate(() => {
      const log = document.querySelector('#cv-log')
      const entry = document.querySelector('.mm-e'); if (!entry) throw new Error('unreachable minimap entry')
      const target = Math.min(log.scrollHeight - log.clientHeight, Math.max(0, log.children[+entry.dataset.i].offsetTop - 16))
      window.motionScrollEnd = target === log.scrollTop ? Promise.resolve() : new Promise(resolve => log.addEventListener('scrollend', resolve, { once: true }))
    })
    animation = await cssMotion(page, '#cv-log', { ...ctx, triggerEvent: 'pointerdown' }, '.mm-e')
    if (!ctx.reduce) await page.evaluate(() => window.motionScrollEnd)
    samples.push(await page.evaluate(() => {
      const log = document.querySelector('#cv-log'), entry = document.querySelector('.mm-e'), row = log.children[+entry.dataset.i]
      const error = log.scrollTop - Math.min(log.scrollHeight - log.clientHeight, Math.max(0, row.offsetTop - 16))
      if (Math.abs(error) > 1 || !row.classList.contains('flash')) throw new Error('minimap jump missed its row')
      return { jumpError: error }
    }))
  } else {
    const box = await page.locator('#cv-map').boundingBox()
    if (!box) throw new Error('unreachable minimap')
    for (const fraction of [.1, .5, .9]) {
      await page.mouse.move(box.x + box.width - 2, box.y + box.height * fraction)
      await page.mouse.down(); await page.mouse.move(box.x + box.width - 2, box.y + box.height * fraction + 40)
      await page.mouse.up()
      samples.push(await page.evaluate(y => {
        const log = document.querySelector('#cv-log'), map = document.querySelector('#cv-map')
        const scale = Math.min(.14, map.clientHeight / log.scrollHeight)
        const error = log.scrollTop - Math.max(0, Math.min(log.scrollHeight - log.clientHeight, y / scale - log.clientHeight / 2))
        if (Math.abs(error) > 1) throw new Error('minimap drag violates its scroll formula')
        return { dragError: error }
      }, box.height * fraction + 40))
      samples.push(await minimapState(page))
    }
  }
  samples.push(await minimapState(page))
  if (initialCount !== await page.locator('#cv-log > *').count()) throw new Error('live conversation changed during measured window')
  return { samples, animation }
}

async function minimapState(page) {
  return page.evaluate(() => {
    const log = document.querySelector('#cv-log'), map = document.querySelector('#cv-map'), view = document.querySelector('.mm-vw')
    const scale = Math.min(.14, map.clientHeight / log.scrollHeight)
    const topError = parseFloat(view.style.top) - log.scrollTop * scale
    const heightError = parseFloat(view.style.height) - Math.max(8, log.clientHeight * scale)
    if (Math.abs(topError) > 1 || Math.abs(heightError) > 1) throw new Error('minimap viewport violates its scale formula')
    return { topError, heightError, flash: !!log.querySelector('.flash') }
  })
}

async function grain(page, ctx) {
  await page.clock.runFor(1008)
  const selectors = ctx.selector ? [ctx.selector] : ['.bd-now', '.ax-uc', '.bd-lanes']
  const samples = [], values = {}
  for (const selector of selectors) {
    if (!await page.locator(selector).count()) throw new Error(`unreachable grain: ${selector}`)
    const value = await page.locator(selector).first().evaluate(el => {
      const style = getComputedStyle(el, '::after')
      return { opacity: Number(style.opacity), display: style.display, mixBlendMode: style.mixBlendMode, backgroundImage: style.backgroundImage,
        animations: el.getAnimations({ subtree: false }).length }
    })
    if (value.animations) throw new Error(`grain is animated: ${selector}`)
    values[selector.replace(/^\./, '')] = { after: value }; samples.push({ selector, display: value.display })
    await pausedAnimations(page, selector)
    await page.evaluate(() => window.motionAnimations.forEach(a => { const t = a.effect.getTiming(); a.currentTime = t.iterations === Infinity ? 0 : Number(t.duration) + Number(t.delay) }))
    await ctx.onFrame?.(0, selector)
    // Isolate the actual pseudo-element; live contents are measured separately.
    const target = page.locator(selector).first(), opts = { animations: 'allow', style: `* { visibility: hidden !important } ${selector}::after { visibility: visible !important }` }
    const before = await captureStable(target, opts, page)
    await page.clock.runFor(512)
    await ctx.onFrame?.(.5, selector)
    await page.clock.runFor(496)
    await ctx.onFrame?.(1, selector)
    const after = await captureStable(target, opts, page)
    if (!before.equals(after)) throw new Error(`grain changes over time: ${selector}`)
  }
  return { samples, ...values }
}

async function inventory(page, ctx) {
  const selector = ctx.selector ?? '#build-root'
  if (!await page.locator(selector).count()) throw new Error(`unreachable inventory: ${selector}`)
  // Inventory compares timing and lifecycle; CSS interaction sequences sample composed styles.
  const animation = await cssMotion(page, selector, { ...ctx, inventoryOnly: true })
  return { samples: [await page.locator(selector).count()], animation }
}

export const SEQUENCES = {
  ...Object.fromEntries(['settle-near-top', 'settle-near-bottom', 'pinned', 'guard-up', 'guard-down', 'tall-band', 'list-view'].map(kind => [`snap.${kind}`, (page, ctx) => snap(page, ctx, kind)])),
  'snap.scroll-curve': scrollCurve,
  'snap.scrollbar-drag': scrollbarDrag,
  'snap.reduce': (page, ctx) => snap(page, ctx, 'settle-near-top'),
  'columns.enter-leave': columns, 'columns.reduce': columns,
  ...Object.fromEntries(['graph', 'gantt', 'list'].map(mode => [`view.switch.${mode}`, (page, ctx) => view(page, ctx, mode)])),
  'view.span': (page, ctx) => view(page, ctx, 'span'),
  'filter.dim': (page, ctx) => filter(page, ctx, 'dim'),
  'feature.focus': (page, ctx) => filter(page, ctx, 'focus'),
  'feature.compact': (page, ctx) => filter(page, ctx, 'compact'),
  'modal.url': (page, ctx) => modal(page, ctx, false, true), 'modal.open': modal, 'modal.close': (page, ctx) => modal(page, ctx, true), 'modal.reduce': modal,
  'minimap.drag': (page, ctx) => minimap(page, ctx, false), 'minimap.jump': (page, ctx) => minimap(page, ctx, true),
  'tree.overlay': tree, 'tree.reduce': tree,
  'loading.spin': (page, ctx) => inventory(page, { ...ctx, selector: '.bd-loading' }),
  'grain.static': grain, 'inventory': inventory,
  'reduce.live-toggle': async (page, ctx) => {
    await page.emulateMedia({ reducedMotion: 'reduce' })
    const rm = await page.locator('#build-root').evaluate(el => el.classList.contains('rm'))
    const settled = await snap(page, { ...ctx, reduce: true, onFrame: undefined }, 'settle-near-top')
    const opened = await modal(page, { ...ctx, reduce: true, onFrame: undefined })
    return { samples: [rm, ...settled.samples, ...opened.samples], frame: settled.frame, animation: opened.animation }
  }
}

import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { dashboardCredentials } from './support/layout-worker.mjs'
test.use({ httpCredentials: dashboardCredentials, viewport: { width: 1440, height: 1000 } })
// Mutation checks can route only the production assets from an isolated worktree.
test.beforeEach(async ({page}, info) => {
  const root = info.project.metadata.agentAssets
  if (!root) return
  for (const name of ['unfiled','list','layout','cards','chains','trees','hook','modal/frame','modal/header','modal/doc']) {
    await page.route('**/build-home/' + name + '.js', async route => route.fulfill({
      body: await readFile(root + '/' + name + '.js','utf8'), contentType:'text/javascript',
    }))
  }
})
async function open(page, dataset = 'unfiled', query = '') {
  await page.goto('/build-fixture/' + dataset + query)
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
  await expect.poll(() => page.evaluate(async () => (await import('/build-home/state.js')).ctx.D?.plan.some(t => t.src?.kind === 'pack'))).toBe(dataset === 'unfiled')
}
const modules = async page => page.evaluate(async () => {
  const {ctx} = await import('/build-home/state.js')
  const t = ctx.D.plan.find(t => t.src?.kind === 'pack')
  ;(await import('/build-home/modal/frame.js')).openModal(t)
  return t
})
test('pack modal keeps its identity, source and inert document link', async ({page}) => {
  await open(page); const t = await modules(page)
  await expect(page.locator('.bm-num')).toHaveText('—'); await expect(page.locator('.bm-num')).toHaveAttribute('title', 'Not filed yet')
  await expect(page.locator('.bm-st')).toHaveText('Planned · not filed')
  await expect(page.locator('.bm-src')).toHaveText('docs/build-plan.md · wave ' + t.src.wave + ' · not filed yet')
  await expect(page.locator('.bm-facts > div').first().locator('b')).toHaveText('—')
  const link = page.locator('[data-a="none"]'); await expect(link).toHaveAttribute('aria-disabled','true')
  await expect.poll(() => new URL(page.url()).searchParams.get('ticket')).toBe(t.id)
  const url = page.url(); await link.click({force:true}); expect(page.url()).toBe(url)
  await page.evaluate(() => Object.defineProperty(navigator, 'clipboard', {configurable:true,value:{writeText:async text => {window.packCopied = text}}}))
  await page.locator('[data-a="link"]').click()
  await expect.poll(() => page.evaluate(() => window.packCopied)).toBe(url)
  await expect(page.locator('#tk-modal')).not.toContainText(/#null|Qnull|undefined|NaN/)
  await page.reload(); await expect(page.locator('.bm-num')).toHaveText('—')
})
test('list shares explicit unfiled labels without nulls', async ({page}) => {
  await open(page, 'unfiled', '?view=list')
  const rows = page.locator('.lr[data-id^="pack:"]'); await expect(rows.first().locator('.c-st .lst')).toHaveText('Not filed')
  await expect(rows.first().locator('.c-st .lst')).toHaveClass(/st-open/)
  await expect(rows.first()).not.toContainText(/null|undefined|NaN/)
  await page.evaluate(async () => {
    const {ctx} = await import('/build-home/state.js'); const t = ctx.D.plan.find(t => t.src?.kind === 'pack')
    ;(await import('/build-home/modal/frame.js')).openModal({...t, title:'<img src=x onerror=alert(1)>'})
  })
  await expect(page.locator('#bm-title')).toContainText('<img src=x onerror=alert(1)>')
  await expect(page.locator('#bm-title img')).toHaveCount(0)
})
// Future guard for existing not-found copy; pack parser acceptance has a separate mutation check.
test('missing old pack link opens the not-found state', async ({page}) => {
  await open(page, 'unfiled', '?ticket=pack:build-plan/BP-999')
  await expect(page.locator('#bm-title')).toContainText('Ticket not found')
})
test('unavailable packs keep an explicit marker', async ({page}) => {
  await open(page, 'unfiled_unavailable')
  await page.evaluate(async () => {
    const {ctx,fx} = await import('/build-home/state.js')
    const mark = ctx.L.secs.plan.marks.find(m => m.label === 'Planning packs unavailable')
    fx.scrollVP(ctx.secs.plan.el.offsetTop + mark.y - 70, false); fx.update()
  })
  const marker = page.locator('.bd-mk.empty').filter({hasText:'Planning packs unavailable'})
  await expect(marker.locator('b')).toHaveText('Planning packs unavailable')
  await expect(marker.locator('p')).toContainText('1 of 2'); await expect(marker.locator('p')).toContainText('checked')
})
test('filing a row replaces the open modal and URL through its alias', async ({page}) => {
  await open(page); const t = await modules(page)
  await page.evaluate(async t => {
    const {ctx} = await import('/build-home/state.js'), {receive} = await import('/build-home/hook.js')
    const filed = {...t,id:'57',num:57,qpos:3,src:null,was:t.id}
    receive({v:1,kind:'diff',epoch:ctx.proto.epoch,generation:ctx.proto.generation+1,now:ctx.snap.now,remove:[t.id],upsert:[filed],set:{}})
  },t)
  await expect(page.locator('.bm-num')).toHaveText('#57')
  await expect.poll(() => new URL(page.url()).searchParams.get('ticket')).toBe('57')
})
test('board and dependency tree use the same unfiled identity', async ({page}) => {
  await open(page)
  const id = await page.evaluate(async () => {
    const {ctx,fx} = await import('/build-home/state.js')
    const t = ctx.D.plan.find(t => t.src?.kind === 'pack')
    const it = ctx.L.secs.plan.items.find(it => it.t.id === t.id)
    fx.scrollVP(ctx.secs.plan.el.offsetTop + it.y - 70, false); fx.update()
    return t.id
  })
  const card = page.locator('.bd-card[data-id="' + id + '"]')
  await expect(card.locator('.bd-status > span').first()).toHaveText('Not filed')
  await expect(card).not.toContainText(/null|undefined|NaN/)
  await page.evaluate(async id => (await import('/build-home/trees.js')).openTree(id), id)
  const node = page.locator('.bd-tn[data-id="' + id + '"]')
  await expect(node.locator('b')).toHaveText('—'); await expect(node.locator('em')).toContainText('Not filed')
  await expect(node).not.toContainText(/null|undefined|NaN/)
})

test('an alias in a replacement snapshot promotes the open pack modal', async ({page}) => {
  await open(page); const t = await modules(page)
  await page.evaluate(async t => {
    const {ctx} = await import('/build-home/state.js'), {receive} = await import('/build-home/hook.js')
    const snapshot = structuredClone(ctx.snap)
    snapshot.generation = ctx.proto.generation + 1
    snapshot.sections.plan = snapshot.sections.plan.filter(row => row.id !== t.id)
    snapshot.sections.plan.push({...t,id:'57',num:57,qpos:3,src:null,was:t.id})
    receive(snapshot)
  },t)
  await expect(page.locator('.bm-num')).toHaveText('#57')
  await expect.poll(() => new URL(page.url()).searchParams.get('ticket')).toBe('57')
})
test('empty planned list retains pack failure count and checked time', async ({page}) => {
  await open(page,'unfiled_unavailable','?view=list')
  await page.evaluate(async () => {
    const {ctx} = await import('/build-home/state.js'), {receive} = await import('/build-home/hook.js')
    receive({v:1,kind:'diff',epoch:ctx.proto.epoch,generation:ctx.proto.generation+1,now:ctx.snap.now,
      remove:ctx.D.plan.map(t => t.id),upsert:[],set:{}})
  })
  const head = page.locator('.lh[data-sec="plan"]')
  await expect(head).toContainText('Planning packs unavailable')
  await expect(head).toContainText('1 of 2'); await expect(head).toContainText('checked')
})

test('resync reads an old pack alias when its filed row is outside the loaded window', async ({page}) => {
  await open(page); const t = await modules(page)
  await page.evaluate(async t => {
    const {ctx} = await import('/build-home/state.js'), {receive} = await import('/build-home/hook.js')
    const original = ctx.push, filed = {...t,id:'57',num:57,qpos:null,src:null,was:t.id,sec:'hist',status:'done'}
    ctx.push = (event,payload) => {
      if (event === 'open-ticket' && payload.id === t.id && !payload.loaded) {
        window.aliasRead = payload.id
        return Promise.resolve({v:1,kind:'ticket',epoch:ctx.proto.epoch,generation:ctx.proto.generation,row:filed})
      }
      return original(event,payload)
    }
    const snapshot = structuredClone(ctx.snap); snapshot.generation++
    snapshot.sections.plan = snapshot.sections.plan.filter(row => row.id !== t.id)
    receive(snapshot)
  },t)
  await expect.poll(() => page.evaluate(() => window.aliasRead)).toBe(t.id)
  await expect(page.locator('.bm-num')).toHaveText('#57')
  await expect.poll(() => new URL(page.url()).searchParams.get('ticket')).toBe('57')
})

test('a missing pack modal remains safe through a replacement snapshot', async ({page}) => {
  page.on('pageerror', error => {throw error})
  await open(page,'unfiled','?ticket=pack:build-plan/BP-999')
  await expect(page.locator('#bm-title')).toContainText('Ticket not found')
  await page.evaluate(async () => {
    const {ctx} = await import('/build-home/state.js'), {receive} = await import('/build-home/hook.js')
    const snapshot = structuredClone(ctx.snap); snapshot.generation++
    receive(snapshot)
  })
  await expect(page.locator('#bm-title')).toContainText('Ticket not found')
  await expect(page.locator('#tk-backdrop')).toHaveClass(/show/)
})

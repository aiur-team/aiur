import { test, expect } from '@playwright/test'
import { PARITY_VIEWPORTS, expectDesignParity, parityContextOptions, loadAllowlist, applyAllowlist, openDesign, openProduct } from '../support/design-parity.mjs'
import { readFile } from 'node:fs/promises'
import { compareRegion } from '../support/build-home-region-parity.mjs'

// Keep the design on live while every product context selects unfiled from the start.
// The fixture dataset is process-global, so parallel cells must never select live.
async function openUnfiledPair(browser,cell) {
  const options=parityContextOptions(cell)
  const contexts=[await browser.newContext(options),await browser.newContext({...options,baseURL:test.info().project.use.baseURL})]
  const pair={design:await contexts[0].newPage(),product:await contexts[1].newPage(),cell,close:()=>Promise.all(contexts.map(context=>context.close()))}
  try {
    pair.allowlist=await loadAllowlist()
    const root=test.info().project.metadata.agentAssets
    if(root) for(const name of ['modal/frame.js','modal/header.js','modal/focus.js','modal/doc.js','modal/conversation.js','modal/conversation-events.js','modal/conversation-items.js','modal/conversation-footer.js','hook.js','home.css','home/19-modal-doc.css']) {
      await pair.product.route('**/build-home/'+name,async route=>route.fulfill({body:await readFile(root+'/'+name,'utf8'),contentType:name.endsWith('.css')?'text/css':'text/javascript'}))
    }
    await openDesign(pair.design,cell)
    await openProduct(pair.product,cell,{dataset:'unfiled',productPending:true})
    return pair
  } catch(error) {await pair.close();throw error}
}

// Full-surface captures retain their failure PNGs without accumulating per-action DOM traces.
test.use({ trace: 'off' })
test.setTimeout(180_000)
for (const viewport of PARITY_VIEWPORTS) for (const theme of ['dark', 'light']) for (const palette of ['aiur', 'gruvbox']) {
  test(`unfiled modal elements ${viewport.viewport.width} ${theme} ${palette}`, async ({ browser }) => {
    const pair = await openUnfiledPair(browser, { ...viewport, theme, palette, dataset: 'live' })
    try {
      await expect(pair.product.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
      const row = await pair.product.evaluate(async () => (await import('/build-home/state.js')).ctx.D.plan.find(t => t.src?.kind === 'pack'))
      expect(row.id).toBe('pack:build-plan/BP-645')
      await pair.design.evaluate(() => window.AiurBuild.open('AIUR-645'))
      await pair.product.evaluate(async id => (await import('/build-home/modal/frame.js')).openById(id), row.id)
      for (const side of ['design', 'product']) await pair[side].locator('#tk-modal').evaluate(el => el.getAnimations().forEach(a => a.finish()))
      for (const selector of ['.bm-st', '.bm-src', '#tk-head .bm-ib[data-a="none"]']) {
        await compareRegion(pair, { name: `unfiled.${viewport.viewport.width}.${theme}.${palette}.${selector}`, region: selector })
      }
      for (const side of ['design', 'product']) await pair[side].locator('#tk-head .bm-ib[data-a="none"]').hover()
      await compareRegion(pair, { name: `unfiled.docs-hover.${viewport.viewport.width}.${theme}.${palette}`, region: '#tk-head .bm-ib[data-a="none"]' })
    } finally { await pair.close() }
  })
}

// Expose original reference operations; never replace their rendering or data.
const designSource = await (await import('node:fs/promises')).readFile(new URL('../../test/fixtures/build_home/design-source/assets/build.js', import.meta.url), 'utf8')
const reference = designSource.replace('  window.AiurBuild = {', `  window.unfiledParity = {
  scroll(id) { const it = L.secs.plan.items.find(it => it.t.id === id); scrollVP(secs.plan.el.offsetTop + it.y - 160, false); update(true); },
  tree: openTree,
  freeze() {S.ready=false;snapping=true;},
};\n  window.AiurBuild = {`)
// Body markers survive renderer replacement and never alter a row's layout.
async function slotGeometry(node,label) {
  let geometry
  await expect.poll(async()=>{
    geometry=await node.evaluate(el=>{
      const b=el.getBoundingClientRect(),s=getComputedStyle(el),ancestor=el.closest('.bd-tree-in')
      const transform=ancestor?getComputedStyle(ancestor).transform:'none',scale=transform==='none'?1:new DOMMatrix(transform).a
      const width=parseFloat(s.width)||b.width/scale
      return {positive:b.width>0&&b.height>0&&Number.isFinite(width)&&width>0,width,box:b.toJSON(),display:s.display,connected:el.isConnected}
    })
    return JSON.stringify(geometry)
  },{message:label}).toMatch(/"positive":true/)
  return geometry
}
async function maskRow(pair,kind,num,slots) {
  const selectors=['AIUR-'+num,'pack:build-plan/BP-'+num].map(id=>'.'+kind+'[data-id="'+id+'"]')
  if(kind==='bd-tn') {
    expect(pair.allowlist.find(entry=>entry.id==='unfiled-tree-reference-width')).toMatchObject({kind:'property',cells:{dataset:'live'},approval:{status:'pending-sign-off'}})
    const measured=await slotGeometry(pair.product.locator(selectors[1]).locator('b'),selectors[1]+' b width')
    for(const [index,page] of [pair.design,pair.product].entries()) await page.evaluate(({selector,width,num})=>{
      const key='unfiled-identity-'+num
      let style=document.getElementById(key)
      if(!style) {style=document.createElement('style');style.id=key;document.head.append(style)}
      style.textContent=selector+' .bd-tn1 b {visibility:hidden;'+(width?'width:'+width+'px;overflow:hidden;':'')+'}'
    },{selector:selectors[index],width:index?null:Math.round(measured.width*64)/64,num})
  }
  for(const [slotIndex,slot] of slots.entries()) {
    const nodes=[pair.design,pair.product].map((page,index)=>page.locator(selectors[index]).locator(slot))
    const boxes=kind==='bd-tn'
      ? (await Promise.all(nodes.map((node,index)=>slotGeometry(node,selectors[index]+' '+slot)))).map(g=>g.box)
      : await Promise.all(nodes.map(node=>node.evaluate(el=>el.getBoundingClientRect().toJSON())))
    const size={width:Math.max(...boxes.map(b=>b.width)),height:Math.max(...boxes.map(b=>b.height))}
    for(const [index,node] of nodes.entries()) await node.evaluate((el,{size,kind,slotIndex,slot})=>{
      const box=el.getBoundingClientRect(),title=el.matches('.bd-tn1 b')?el.nextElementSibling:null
      const preceding=title?el.previousElementSibling:el.matches('.bd-id')?el.previousElementSibling:null
      const left=preceding?Math.min(1/devicePixelRatio,Math.max(0,(box.left-preceding.getBoundingClientRect().right)/2)):0
      const right=title?Math.min(1/devicePixelRatio,Math.max(0,title.getBoundingClientRect().left-box.right)):0
      const floor=value=>Math.floor(value*64)/64,ceil=value=>Math.ceil(value*64)/64
      const x=left?ceil(box.left-left):floor(box.left),y=floor(box.top)
      const endX=size.width?(right?floor(box.left+size.width+right):ceil(box.left+size.width)):x
      const endY=size.height?ceil(box.top+size.height):y
      const mask=document.createElement('span')
      Object.assign(mask.dataset,{unfiledMask:kind,rowId:el.closest('[data-id]').dataset.id,slot:String(slotIndex),ownedSlot:slot,parityRegion:kind==='bd-tn'?'.bd-tree-s':'#bd-vp'})
      Object.assign(mask.style,{position:'fixed',display:'block',boxSizing:'border-box',margin:'0',padding:'0',border:'0',left:x+'px',top:y+'px',width:endX-x+'px',height:endY-y+'px',background:'transparent',pointerEvents:'none',zIndex:'2147483647'})
      document.body.append(mask)
      const m=mask.getBoundingClientRect()
      if(title&&m.right>=title.getBoundingClientRect().left) throw new Error('Identity mask overlaps the unmasked title')
      if(preceding&&m.left<=preceding.getBoundingClientRect().right) throw new Error('Identity mask overlaps the unmasked icon or dot')
    },{size,kind,slotIndex,slot})
  }
}
async function maskVisible(pair,kind,slots) {
  // Scrolling can leave a card under the view button's pointer. Finish its hover
  // transition before measuring fixed masks; later movement would invalidate them.
  for(const page of [pair.design,pair.product]) {
    await page.mouse.move(0,0)
    await page.evaluate(()=>document.getAnimations().filter(a=>Number.isFinite(a.effect?.getComputedTiming().endTime)).forEach(a=>a.finish()))
  }
  for(const page of [pair.design,pair.product]) await page.locator('body > [data-unfiled-mask]').evaluateAll(nodes=>nodes.forEach(node=>node.remove()))
  await applyAllowlist(pair,pair.cell)
  for(const num of ids) {
    const counts=await Promise.all([pair.design,pair.product].map((page,index)=>page.locator('.'+kind+'[data-id="'+(index?'pack:build-plan/BP-':'AIUR-')+num+'"]').count()))
    expect(counts[1],`matching rendered row ${num}`).toBe(counts[0])
    if(counts[0]) await maskRow(pair,kind,num,slots)
  }
}
async function assertMaskGeometry(pair,kind) {
  for(const [side,page] of [['design',pair.design],['product',pair.product]]) {
    const failures=await page.locator('body > [data-unfiled-mask]').evaluateAll((markers,kind)=>{
      if(!markers.length) return [{reason:'no markers'}]
      return markers.flatMap(marker=>{
        const owned=document.querySelector('.'+kind+'[data-id="'+marker.dataset.rowId+'"]')?.querySelector(marker.dataset.ownedSlot)
        const detail={row:marker.dataset.rowId,surface:kind,slot:marker.dataset.ownedSlot}
        if(!owned) return [{...detail,reason:'owned slot missing'}]
        const a=owned.getBoundingClientRect(),b=marker.getBoundingClientRect()
        const title=owned.matches('.bd-tn1 b')?owned.nextElementSibling:null,preceding=title?owned.previousElementSibling:owned.matches('.bd-id')?owned.previousElementSibling:null
        const reasons=[]
        if(!a.width||!a.height) {if(b.width&&b.height) reasons.push('empty slot has visible mask')}
        else {
          if(!(b.width>0&&b.height>0)) reasons.push('mask empty')
          if(Math.abs(a.top-b.top)>=1/64) reasons.push('top differs')
          if(b.left>a.left||b.right<a.right||b.bottom<a.bottom) reasons.push('owned slot not contained')
          if(title&&b.right>=title.getBoundingClientRect().left) reasons.push('title overlap')
          if(preceding&&b.left<=preceding.getBoundingClientRect().right) reasons.push('icon or dot overlap')
        }
        return reasons.length?[{...detail,reasons,owned:a.toJSON(),marker:b.toJSON(),title:title?.getBoundingClientRect().toJSON(),preceding:preceding?.getBoundingClientRect().toJSON()}]:[]
      })
    },kind)
    expect(failures,side+' current identity mask geometry').toEqual([])
  }
}
const ids = Array.from({length:16}, (_,i) => 645+i)
for (const viewport of PARITY_VIEWPORTS) for (const theme of ['dark','light']) for (const palette of ['aiur','gruvbox']) {
  test(`unfiled row cells ${viewport.viewport.width} ${theme} ${palette}`, async ({browser}) => {
    test.setTimeout(600_000)
    const pair = await openUnfiledPair(browser,{...viewport,theme,palette,dataset:'live'})
    try {
      await pair.design.route('**/assets/build.js*',route => route.fulfill({body:reference,contentType:'text/javascript'}))
      await pair.design.reload()
      await expect.poll(() => pair.design.evaluate(() => !!window.unfiledParity && !!document.querySelector('.bd-card'))).toBe(true)
      await expect(pair.product.locator('#build-root')).toHaveAttribute('data-build-generation',/\d+/)
      for (const page of [pair.design,pair.product]) await expect(page.locator('.bd-content')).not.toHaveClass(/\bscrolling\b/)
      await pair.design.evaluate(() => window.unfiledParity.freeze())
      await pair.product.evaluate(async () => {const {S,ctx}=await import('/build-home/state.js');S.ready=false;ctx.snapping=true})
      // The sticky live band is unrelated to isolated planned-card pixels.
      for (const page of [pair.design,pair.product]) await page.locator('#bd-now').evaluate(el => {el.style.visibility='hidden'})
      const surfaces = [
        {kind:'bd-card',view:'graph',region:'#bd-vp',slots:['.bd-id','.bd-status > span:first-child']},
        {kind:'lr',view:'list',region:'#bd-vp',slots:['.c-id','.c-pg .lr-mu','.c-st .lst']},
        {kind:'bd-tn',view:'graph',region:'.bd-tree-s',slots:['b','em']},
      ]
      for (const surface of surfaces) {
        for (const page of [pair.design,pair.product]) await page.locator('[data-v="'+surface.view+'"]').click()
        if(surface.kind!=='bd-tn') for(const page of [pair.design,pair.product]) await page.locator('#bd-vp').evaluate(el=>el.scrollIntoView({block:'center',inline:'nearest',behavior:'instant'}))
        if(surface.kind==='bd-tn') await pair.product.evaluate(async()=>{
          const {H,loadEarlier}=await import('/build-home/history.js')
          for(let page=0;H.more&&page<100;page++) if(!await loadEarlier(31)) throw new Error('History parity intake failed')
          if(H.more) throw new Error('History parity intake remained incomplete')
        })
        if(surface.kind==='bd-tn') {
          const entry=pair.allowlist.find(entry=>entry.id==='unfiled-tree-underlay-thumb')
          expect(entry).toMatchObject({kind:'design-style',cells:{dataset:'live'},approval:{status:'pending-sign-off'}})
          for(const page of [pair.design,pair.product]) await page.addStyleTag({content:entry.css})
        }
        if(surface.kind==='bd-card') for(const page of [pair.design,pair.product]) await page.locator('#bd-now').evaluate(el=>{el.style.visibility='hidden'})
        const covered = new Set()
        for (const num of ids) {
          if (covered.has(num)) continue
          if (surface.kind === 'bd-card') {
            await pair.design.evaluate(num => window.unfiledParity.scroll('AIUR-'+num),num)
            await pair.product.evaluate(async num => {
              const {ctx,fx}=await import('/build-home/state.js')
              const it=ctx.L.secs.plan.items.find(it=>it.t.id==='pack:build-plan/BP-'+num)
              fx.scrollVP(ctx.secs.plan.el.offsetTop+it.y-160,false);fx.update()
            },num)
          } else if (surface.kind === 'lr') {
            for (const [index,page] of [pair.design,pair.product].entries()) await page.locator('.lr[data-id="'+(index?'pack:build-plan/BP-':'AIUR-')+num+'"]').evaluate(el=>{const vp=document.querySelector('#bd-vp');vp.scrollTop+=el.getBoundingClientRect().top-vp.getBoundingClientRect().top-70})
          } else {
            await pair.design.evaluate(num=>window.unfiledParity.tree('AIUR-'+num),num)
            await pair.product.evaluate(async num=>(await import('/build-home/trees.js')).openTree('pack:build-plan/BP-'+num),num)
            for(const page of [pair.design,pair.product]) {
              await page.locator('.bd-tree-s').evaluate(el=>el.scrollIntoView({block:'center',inline:'nearest',behavior:'instant'}))
              // History intake schedules a trailing relayout which rebuilds tree nodes.
              await page.waitForTimeout(350)
            }
          }
          await maskVisible(pair,surface.kind,surface.slots)
          const visible = await Promise.all([pair.design,pair.product].map(page=>page.locator(surface.region).evaluate((root,kind)=>{
            const box=root.getBoundingClientRect()
            const top=Math.max(0,box.top),left=Math.max(0,box.left)
            const viewport={top,left,bottom:top+Math.floor(Math.min(innerHeight,box.bottom)-top),right:left+Math.floor(Math.min(innerWidth,box.right)-left)}
            return [...root.querySelectorAll('.'+kind+'[data-id]')].filter(el=>{
              const b=el.getBoundingClientRect()
              const inside=b=>b.top>=viewport.top+(kind==='bd-card'?46:0) && b.bottom<=viewport.bottom && b.left>=viewport.left && b.right<=viewport.right
              if(kind!=='lr') return inside(b)
              const style=getComputedStyle(el)
              const content={top:b.top+parseFloat(style.borderTopWidth),bottom:b.bottom-parseFloat(style.borderBottomWidth),left:b.left+parseFloat(style.paddingLeft),right:b.right-parseFloat(style.paddingRight)}
              const children=[...el.querySelectorAll(':scope > [role="cell"], .c-id > *, .c-st > *')].map(child=>child.getBoundingClientRect()).filter(box=>box.width&&box.height)
              return inside(content) && children.every(inside)
            }).map(el=>Number(el.dataset.id.replace(/^(AIUR-|pack:build-plan\/BP-)/,''))).filter(n=>n>=645&&n<=660).sort((a,b)=>a-b)
          },surface.kind)))
          expect(visible[1],surface.kind+' visible identities').toEqual(visible[0])
          expect(visible[1],surface.kind+' requested row content is fully captured').toContain(num)
          await assertMaskGeometry(pair,surface.kind)
          await expectDesignParity(pair,{name:`unfiled-${viewport.viewport.width}-${theme}-${palette}-${surface.kind}-${num}`,region:surface.region,preserveAnimations:true,regionCapture:surface.kind==='bd-tn'?'contained':'visible'})
          visible[1].forEach(id=>covered.add(id))
        }
        expect([...covered].sort((a,b)=>a-b),surface.kind+' captures cover every unfiled row').toEqual(ids)
        if(surface.kind==='bd-tn') for(const page of [pair.design,pair.product]) {await page.locator('#bd-tree-x').evaluate(el=>el.click());await page.evaluate(()=>window.scrollTo(0,0))}
      }
    } finally {await pair.close()}
  })
}

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fmtLeft, avgKnown, stripHTML } from '../../priv/static/build-home/usage-render.js'
const now=1791408000000
const fixture = name => JSON.parse(readFileSync(new URL(`../../test/fixtures/build_home/usage/${name}.json`,import.meta.url)))
const html = name => stripHTML(fixture(name),now)
const tip = text => text.replaceAll('&quot;','"').replaceAll('&amp;','&')

test('design durations floor minutes, pad hours and omit zero day hours', () => {
  assert.deepEqual([87,250,10020,1560,182,4560,58,7260,161,6300,135,3240,37,20,31680].map(m => fmtLeft(m*60000)),
    ['1h 27m','4h 10m','6d 23h','1d 2h','3h 02m','3d 4h','58m','5d 1h','2h 41m','4d 9h','2h 15m','2d 6h','37m','20m','22d'])
  assert.equal(fmtLeft(119999), '1m'); assert.equal(fmtLeft(-60000),'0m')
})
test('mean includes only known integers including exact zero', () => {
  assert.deepEqual([[null,40],[null],[0]].map(avgKnown),[40,null,0])
})
test('unknown account is dashed, partial account retains value and honest tooltip', () => {
  const u=fixture('partial'); u.apis=[]; const s=stripHTML(u,now)
  assert.match(s,/<span class="ax-seg none"><\/span>/)
  assert.match(s,/<span class="ax-pc">40%/)
  assert.match(s,/<i class="" style="width:40%"/)
  assert.match(tip(s), /"Max · work","not observed"/)
  assert.match(s,/×2/)
  const unknown=fixture('unknown');unknown.apis=[]
  assert.doesNotMatch(stripHTML(unknown,now),/0%|class="z"|null%/)
  unknown.providers[0].session.acc=[]
  assert.match(stripHTML(unknown,now),/class="ax-seg none"/)
})
test('zero and threshold tones agree between percent and segment', () => {
  for (const [n,cls,seg] of [[0,'','z'],[79,'',''],[80,' hi',' hi'],[95,' max',' max']]) {
    const u=fixture('unknown');u.apis=[];u.providers[0].session.acc=[n]
    const s=stripHTML(u,now)
    assert.ok(s.includes(`<span class="ax-pc${cls}">${n}%`))
    assert.ok(s.includes(`<i class="${seg}" style="width:${n}%"`))
  }
})
test('reset unknown and ended never claim a countdown or window length', () => {
  const u=fixture('unknown');u.apis=[];const s=stripHTML(u,now)
  assert.match(s,/reset unknown/);assert.doesNotMatch(s,/resets in/)
  const e=fixture('ended');e.apis=[];e.providers[0].session.win=null
  const ended=stripHTML(e,now)
  assert.match(ended,/window ended/);assert.match(ended,/class="ax-ln stale"/)
  assert.doesNotMatch(ended,/<em>|resets in/)
})
test('stale observation ages, never observed, holds and provider notes appear in tips', () => {
  assert.match(html('stale'),/ax-r2 stale/)
  assert.match(tip(html('stale')),/ · stale.*"Observed","12m ago"/)
  const u=fixture('stale');u.providers[0].observed_at=null
  assert.match(tip(stripHTML(u,now)),/"Observed","never"/)
  assert.match(tip(html('hold')),/"Held for","37m"/)
  assert.match(tip(html('none')),/Awaiting first observation/)
  assert.match(tip(html('none')),/Last known 40% \(previous boot\)/)
})
test('credits distinguish unknown amounts, missing windows keep a visible row', () => {
  const s=html('credits')
  assert.match(s,/<b class="ax-usd">\$10.40/)
  assert.match(s,/<span class="ax-no">unknown/)
  assert.doesNotMatch(s,/<b class="ax-usd">unknown/)
  assert.match(s,/ElevenLabs · renews in 1h 00m/)
  assert.equal((html('onewin').match(/class="ax-ln"/g)??[]).length,2)
  assert.match(html('onewin'),/<span class="ax-no">not observed<\/span>/)
})
test('all payload text is escaped and unknown identity keys use mono fallback', () => {
  const s=html('hostile')
  assert.doesNotMatch(s,/<img|<script/)
  for (const cls of ['ax-mono','ax-tg','ax-usd']) assert.match(s,new RegExp(`class="${cls}"[^>]*>&lt;img`))
  const u=fixture('one');Object.assign(u.providers[0],{logo:'muse',mono:null,icon:'toString',name:'Zed'})
  assert.match(stripHTML(u,now),/class="ax-mono">Z/)
  assert.match(html('n2'),/class="ax-ic"><svg/)
  assert.match(html('n7'),/n7 lay-cols/)
  assert.match(html('n2'),/n2 lay-rows/)
})
test('empty counts, locked privacy and unavailable cause render explicit states', () => {
  assert.match(html('one'),/APIs<span>1 API/)
  assert.match(html('one'),/<span class="ax-cnt" id="ax-cnt">1 model/)
  assert.match(html('empty'),/0 models/);assert.match(html('empty'),/No providers configured/)
  const locked=html('locked');assert.match(locked,/role="status"/)
  assert.match(locked,/Financial data locked/);assert.doesNotMatch(locked,/ax-ln|%|\$/)
  assert.match(html('unavailable'),/Usage unavailable.*The usage source failed/)
  assert.match(stripHTML({state:'unavailable',reason:'mystery'},now),/Reason unknown/)
})

test('before the first snapshot usage leaves the dead-render host untouched', async () => {
  const {resetState}=await import('../../priv/static/build-home/state.js')
  const {renderUsage}=await import('../../priv/static/build-home/usage.js')
  resetState(); assert.doesNotThrow(renderUsage)
})

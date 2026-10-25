// Phone cells and probes shared by the Chromium phone spec and the hand-run WebKit spec (MP-E8-C12-T04).
import { test } from '@playwright/test'
import { FIXTURE_META, openProduct, parityContextOptions } from './design-parity.mjs'

export const PHONE_CELLS = {
  p360: { width: 360, height: 780 },
  p390: { width: 390, height: 844 },
  p430: { width: 430, height: 932 },
}
export const PHONE_DATASETS = FIXTURE_META.datasets
export const phoneCell = (name, dataset = 'live') => ({ viewport: PHONE_CELLS[name], deviceScaleFactor: 3, isMobile: true, hasTouch: true, theme: 'dark', palette: 'gruvbox', dataset })

export async function openPhoneProduct(browser, cell, opts = {}) {
  const context = await browser.newContext({ ...parityContextOptions(cell), baseURL: test.info().project.use.baseURL })
  const page = await context.newPage()
  try { await openProduct(page, cell, opts) } catch (error) { await context.close(); throw error }
  return { page, close: () => context.close() }
}

export const geom = page => page.evaluate(() => {
  const q = s => document.querySelector(s)
  const lefts = sel => [...new Set([...document.querySelectorAll(sel)].map(c => Math.round(parseFloat(c.style.left) * 2) / 2))].sort((a, b) => a - b)
  const hist = [...document.querySelectorAll('#bd-sec-hist .bd-layer > .bd-card')]
  return {
    rootW: q('#build-root').clientWidth, vpW: q('#bd-vp').clientWidth, vpH: q('#bd-vp').clientHeight,
    flow: q('#bd-content').classList.contains('flow'),
    histLefts: lefts('#bd-sec-hist .bd-layer > .bd-card'), bandLefts: lefts('#bd-now .bd-layer > .bd-card'),
    bandCards: document.querySelectorAll('#bd-now .bd-layer > .bd-card').length,
    maxRight: Math.max(0, ...hist.map(c => parseFloat(c.style.left) + parseFloat(c.style.width))),
    lanes: document.querySelectorAll('.bd-lane').length, laneG: q('.bd-lane-g')?.textContent, edgesHidden: q('#bd-edges').classList.contains('hide'),
    docScrollW: document.documentElement.scrollWidth, cards: document.querySelectorAll('#bd-content .bd-card').length,
  }
})

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { boardAudit, contrastRatio } from '../tests/support/build-home-a11y-audit.mjs'
import { expectAuditClean } from '../tests/support/browser-helpers.mjs'

const node = key => ({ target: ['.bd-cx'], any: [{ data: { messageKey: key } }], all: [], none: [] })
const audit = (key, id = 'color-contrast') => ({ violations: [], incomplete: [{ id, nodes: [node(key)] }] })

test('only overlap-caused contrast incompletes are exempted', () => {
  const input = audit('bgOverlap')
  expectAuditClean(boardAudit(input))
  assert.equal(input.incomplete[0].nodes.length, 1)
  for (const key of ['bgColor', 'fgColor', 'nonBmp', 'imgNode', undefined]) {
    assert.throws(() => expectAuditClean(boardAudit(audit(key))))
  }
  const pseudo = audit('pseudoContent')
  pseudo.incomplete[0].nodes[0].any[0].relatedNodes = [{ target: ['#bd-now'] }]
  expectAuditClean(boardAudit(pseudo))
  pseudo.incomplete[0].nodes[0].any[0].relatedNodes = [{ target: ['#unrelated'] }]
  assert.throws(() => expectAuditClean(boardAudit(pseudo)))
  const edges = audit('imgNode')
  edges.incomplete[0].nodes[0].any[0].relatedNodes = [{ target: ['#bd-lanes'] }, { target: ['#bd-edges'] }]
  expectAuditClean(boardAudit(edges))
  // Future regression guard for the existing short-text/edge diagnostic.
  const short = structuredClone(edges)
  short.incomplete[0].nodes[0].any[0].data.messageKey = 'shortTextContent'
  expectAuditClean(boardAudit(short))
  short.incomplete[0].nodes[0].any[0].relatedNodes.push({ target: ['#unrelated'] })
  assert.throws(() => expectAuditClean(boardAudit(short)))
  const image = structuredClone(edges)
  image.incomplete[0].nodes[0].any[0].relatedNodes.push({ target: ['#unrelated-image'] })
  assert.throws(() => expectAuditClean(boardAudit(image)))
  const mixed = audit('bgOverlap')
  mixed.incomplete[0].nodes[0].all = node('bgColor').any
  assert.throws(() => expectAuditClean(boardAudit(mixed)))
  const violation = { violations: [{ id: 'color-contrast', nodes: [node('bgOverlap')] }], incomplete: [] }
  assert.throws(() => expectAuditClean(boardAudit(violation)))
  assert.deepEqual(boardAudit(audit('bgOverlap', 'other-rule')), audit('bgOverlap', 'other-rule'))
})

test('token arithmetic distinguishes AA failures from passing text pairs', () => {
  assert.equal(contrastRatio('#000000', '#ffffff'), 21)
  assert.equal(contrastRatio('#ffffff', '#ffffff'), 1)
  assert.ok(contrastRatio('#777269', '#ffffff') >= 4.5)
  assert.ok(contrastRatio('#777269', '#f4f2ed') < 4.5)
  assert.ok(Math.abs(contrastRatio('#777269', '#ffffff') - 4.7778337244) < 0.000001)
  assert.equal(contrastRatio('#777269', '#ffffff'), contrastRatio('#ffffff', '#777269'))
  assert.throws(() => contrastRatio('transparent', '#ffffff'))
})

test('partial obscuring accepts only card-over-lane provenance', () => {
  const partial = audit('elmPartiallyObscured')
  partial.incomplete[0].nodes[0].target = ['div[title="Bugs"] > span']
  const check = partial.incomplete[0].nodes[0].any[0]
  check.relatedNodes = [{ target: ['#bd-lanes'] }, { target: ['div[data-id="1260"] > .bd-in'] }]
  expectAuditClean(boardAudit(partial))
  for (const target of ['#unrelated', '.bd-in', 'div[data-id="1260"] > .unrelated']) {
    const extra = structuredClone(partial)
    extra.incomplete[0].nodes[0].any[0].relatedNodes.push({ target: [target] })
    assert.throws(() => expectAuditClean(boardAudit(extra)))
  }
  check.relatedNodes = [{ target: ['div[data-id="1260"] > .bd-in'] }]
  assert.throws(() => expectAuditClean(boardAudit(partial)))
  check.relatedNodes = [{ target: ['#bd-lanes'] }]
  assert.throws(() => expectAuditClean(boardAudit(partial)))
})
